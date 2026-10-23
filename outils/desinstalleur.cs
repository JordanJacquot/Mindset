// Desinstaller Mindset.exe : retire Mindset du PC, avec les applis qu'il a installées, ses tâches planifiées, ses traces
// dans le registre, ses raccourcis et (si on le demande) ses données.
// Il ne dépend ni de Mindset.exe ni du code PowerShell de Mindset : il marche même si fichiers\Mindset.ps1 est supprimé
// ou abîmé. Il est livré à côté de Mindset.exe, et « Applications installées » de Windows le lance (UninstallString).
// Compilé par construire.ps1 (et par tester-desinstallation.ps1, pour les tests).
//
//   Desinstaller Mindset.exe              la fenêtre « Désinstaller Mindset » (case « Supprimer aussi mes données »,
//                                         décochée au départ)
//   Desinstaller Mindset.exe -Nettoyer    nettoyage de secours, sans question : retire tout ce qui reste de Mindset, même
//                                         d'une installation à moitié cassée. Se relance sans souci : ce qui est déjà parti
//                                         est simplement passé. Les données sont gardées, sauf avec -SupprimerDonnees.
//
// Ce qui est retiré (le même tableau que l'issue #1) :
//   programmes        <Program Files>\Mindset (Mindset et ses applis) et X:\Mindset\Programmes sur chaque disque fixe
//   applis            le désinstalleur de chaque appli qui en a un (champ « desinstalleur » de apps.json, Nevermind) est
//                     lancé d'abord ; s'il échoue, la désinstallation continue et le signale. Il reçoit le choix de la
//                     case : -GarderDonnees ou -SupprimerDonnees (il ne pose alors pas la question). Une ancienne version
//                     qui supprime quand même ses données est repérée (son dossier de données a disparu) et le bilan le dit
//   tâches          tout le dossier « \Mindset\ » du Planificateur (démarrage, installation, « <Appli> (aide) »...)
//   registre          HKLM\SOFTWARE\Mindset, HKLM\...\Uninstall\Mindset, la valeur « Mindset » de HKCU\...\Run
//   raccourcis        Mindset.lnk sur le Bureau et dans le menu Démarrer
//   données (option)  %LOCALAPPDATA%\Mindset et X:\Mindset\Donnees ; sinon seuls les téléchargements en cours partent
//   X:\Mindset        retiré s'il est vide
// Un élément qui ne part pas est affiché à la fin (« ce qui reste »), jamais seulement noté dans le journal. Dans ce cas,
// ce programme et l'entrée « Applications installées » restent en place, pour pouvoir relancer la désinstallation.
//
// Déroulement : lancé sans les droits, il se relance en administrateur (une demande de Windows) en passant l'utilisateur
// (-Sid). En administrateur, il se copie dans un dossier temporaire protégé et s'y relance (-Copie) : un programme qui
// tourne ne peut pas supprimer son propre fichier, et il doit vider le dossier des programmes où il se trouve.
//
// Options internes (relances et tests) :
//   -Sid <S-1-5-21-...>                       l'utilisateur qui a lancé la désinstallation (son registre, son Bureau...)
//   -Copie -Original <exe> -AttendrePid <n>   la copie temporaire : attend la fin du premier, puis travaille
//   -Silencieux                               aucune fenêtre ni message
//   -Rapport <fichier>                        le bilan en JSON (ok, faits, restes, alertes, texte affiché...)
//   -Test <fichier.json>                      faux environnement (tests) : dossiers, clé du registre sous HKCU\Software\
//                                             MindsetTest-..., dossier de tâches \MindsetTest-..., faux disques. Jamais de
//                                             demande de Windows, rien de réel n'est touché.
//   -EssaiFenetre <0|1>                       (avec -Test) la fenêtre, hors de l'écran et sans prendre la main : la case
//                                             est laissée telle quelle (0) ou cochée (1), puis « Désinstaller » se clique seul
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("Désinstaller Mindset")]
[assembly: AssemblyProduct("Mindset")]
[assembly: AssemblyDescription("Retire Mindset et ses applis du PC")]

// Les options de la ligne de commande
class Options
{
    public bool Nettoyer, SupprimerDonnees, Silencieux, Copie;
    public string Sid, Original, Rapport, Test;
    public int AttendrePid, EssaiFenetre = -1;

    public static Options Lire(string[] args)
    {
        Options o = new Options();
        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i].ToLowerInvariant();
            string suivant = i + 1 < args.Length ? args[i + 1] : null;
            switch (a)
            {
                case "-nettoyer": o.Nettoyer = true; break;
                case "-supprimerdonnees": o.SupprimerDonnees = true; break;
                case "-silencieux": o.Silencieux = true; break;
                case "-copie": o.Copie = true; break;
                case "-sid": o.Sid = suivant; i++; break;
                case "-original": o.Original = suivant; i++; break;
                case "-rapport": o.Rapport = suivant; i++; break;
                case "-test": o.Test = suivant; i++; break;
                case "-attendrepid": int.TryParse(suivant, out o.AttendrePid); i++; break;
                case "-essaifenetre": o.EssaiFenetre = suivant == "1" ? 1 : 0; i++; break;
            }
        }
        if (o.Sid != null && !Regex.IsMatch(o.Sid, @"^S-1-5-21-\d+-\d+-\d+-\d+$")) o.Sid = null;
        return o;
    }
}

// Où sont les choses : les vrais emplacements, ou ceux d'un faux environnement de test
class Lieux
{
    public bool Test;
    public string ProgramFiles, LocalAppData, Bureau, Menu, Temp, DossierTaches;
    public List<string> Disques = new List<string>();
    public RegistryKey BaseMachine, BaseUtilisateur;
    public string CleDesinstall, CleMindset, CleRun;

    public static Lieux Reels(string sid)
    {
        Lieux l = new Lieux();
        string pf = Environment.GetEnvironmentVariable("ProgramW6432");   // (le vrai Program Files, même vu d'un programme 32 bits)
        if (string.IsNullOrEmpty(pf)) pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        l.ProgramFiles = pf;
        l.BaseMachine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        l.CleDesinstall = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Mindset";
        l.CleMindset = @"SOFTWARE\Mindset";
        l.CleRun = @"Software\Microsoft\Windows\CurrentVersion\Run";
        l.DossierTaches = @"\Mindset";
        l.Temp = Path.GetTempPath();
        l.BaseUtilisateur = Registry.CurrentUser;
        l.LocalAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        l.Bureau = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        l.Menu = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
        // Relancé en administrateur par un autre compte (celui d'un administrateur) : le registre et les dossiers sont
        // ceux de l'utilisateur qui a lancé la désinstallation, pas ceux de l'administrateur
        string moi = WindowsIdentity.GetCurrent().User.Value;
        if (sid != null && !string.Equals(sid, moi, StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                RegistryKey u = RegistryKey.OpenBaseKey(RegistryHive.Users, RegistryView.Registry64).OpenSubKey(sid);
                if (u != null)
                {
                    l.BaseUtilisateur = u;
                    using (RegistryKey sf = u.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"))
                    {
                        if (sf != null)
                        {
                            l.LocalAppData = (sf.GetValue("Local AppData") as string) ?? l.LocalAppData;
                            l.Bureau = (sf.GetValue("Desktop") as string) ?? l.Bureau;
                            l.Menu = (sf.GetValue("Programs") as string) ?? l.Menu;
                        }
                    }
                }
            }
            catch { }
        }
        foreach (DriveInfo d in DriveInfo.GetDrives())
        {
            try { if (d.DriveType == DriveType.Fixed && d.IsReady) l.Disques.Add(d.RootDirectory.FullName); } catch { }
        }
        return l;
    }

    // Faux environnement : tout vient du fichier de test, et les noms de la clé et du dossier de tâches doivent être des
    // noms de test (une erreur dans le fichier ne peut pas viser les vrais)
    public static Lieux DeTest(string fichier)
    {
        Dictionary<string, object> c = (Dictionary<string, object>)new JavaScriptSerializer().DeserializeObject(File.ReadAllText(fichier, Encoding.UTF8));
        Lieux l = new Lieux();
        l.Test = true;
        string registre = (string)c["Registre"], taches = (string)c["Taches"];
        if (!Regex.IsMatch(registre, @"^Software\\MindsetTest-[0-9a-f]{8,32}$")) throw new Exception("Clé de test refusée : " + registre);
        if (!Regex.IsMatch(taches, @"^\\MindsetTest-[0-9a-f]{8,32}$")) throw new Exception("Dossier de tâches de test refusé : " + taches);
        l.ProgramFiles = (string)c["ProgramFiles"];
        l.LocalAppData = (string)c["LocalAppData"];
        l.Bureau = (string)c["Bureau"];
        l.Menu = (string)c["Menu"];
        l.Temp = (string)c["Temp"];
        foreach (object d in (object[])c["Disques"]) l.Disques.Add((string)d);
        l.BaseMachine = Registry.CurrentUser;
        l.BaseUtilisateur = Registry.CurrentUser;
        l.CleDesinstall = registre + @"\Uninstall\Mindset";
        l.CleMindset = registre + @"\Mindset";
        l.CleRun = registre + @"\Run";
        l.DossierTaches = taches;
        return l;
    }

    // Les dossiers des programmes qui existent : <Program Files>\Mindset, X:\Mindset\Programmes
    public List<string> RacinesProgrammes()
    {
        List<string> r = new List<string>();
        Ajouter(r, Path.Combine(ProgramFiles, "Mindset"));
        foreach (string d in Disques) Ajouter(r, Path.Combine(d, @"Mindset\Programmes"));
        return r;
    }

    // Les dossiers des données qui existent : %LOCALAPPDATA%\Mindset, X:\Mindset\Donnees
    public List<string> RacinesDonnees()
    {
        List<string> r = new List<string>();
        if (!string.IsNullOrEmpty(LocalAppData)) Ajouter(r, Path.Combine(LocalAppData, "Mindset"));
        foreach (string d in Disques) Ajouter(r, Path.Combine(d, @"Mindset\Donnees"));
        return r;
    }

    static void Ajouter(List<string> r, string d)
    {
        try
        {
            d = Path.GetFullPath(d).TrimEnd('\\');
            if (Directory.Exists(d) && !r.Exists(x => string.Equals(x, d, StringComparison.OrdinalIgnoreCase))) r.Add(d);
        }
        catch { }
    }
}

// Ce qui a été fait, ce qui reste (à afficher), et ce qu'il faut savoir (un désinstalleur d'appli qui a échoué)
class Bilan
{
    public List<string> Faits = new List<string>(), Restes = new List<string>(), Alertes = new List<string>();
    public Action<string> SurEtape;
    public string FichierJournal;

    public void Etape(string t) { Journal(t); if (SurEtape != null) SurEtape(t); }
    public void Fait(string t) { Faits.Add(t); Journal("Fait : " + t); }
    public void Reste(string t) { Restes.Add(t); Journal("Reste : " + t); }
    public void Alerte(string t) { Alertes.Add(t); Journal("À savoir : " + t); }
    public void Journal(string t)
    {
        try { File.AppendAllText(FichierJournal, DateTime.Now.ToString("s") + " " + t + "\r\n", new UTF8Encoding(false)); } catch { }
    }
}

// Une appli de la suite qui a son propre désinstalleur (Nevermind)
class AppliGeree
{
    public string Nom, Dossier, Exe, Desinstalleur;
}

static class Desinstalleur
{
    const string NomExe = "Desinstaller Mindset.exe";

    [STAThread]
    static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Options o = Options.Lire(args);
        Lieux lieux;
        try { lieux = o.Test != null ? Lieux.DeTest(o.Test) : Lieux.Reels(o.Sid); }
        catch (Exception e)
        {
            if (!o.Silencieux) MessageBox.Show("La désinstallation ne peut pas démarrer :\n\n" + e.Message, "Désinstaller Mindset", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        string moi = Path.GetFullPath(Application.ExecutablePath);

        // 1. Les droits administrateur (jamais en test) : une demande de Windows, puis ce programme se relance
        if (!lieux.Test && !EstAdmin())
        {
            StringBuilder a = new StringBuilder();
            if (o.Nettoyer) a.Append("-Nettoyer ");
            if (o.SupprimerDonnees) a.Append("-SupprimerDonnees ");
            if (o.Silencieux) a.Append("-Silencieux ");
            a.Append("-Sid ").Append(WindowsIdentity.GetCurrent().User.Value);
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(moi, a.ToString());
                psi.UseShellExecute = true; psi.Verb = "runas"; psi.WorkingDirectory = Environment.SystemDirectory;
                Process.Start(psi);
                return 0;
            }
            catch (Win32Exception e)
            {
                if (!o.Silencieux)
                {
                    string m = e.NativeErrorCode == 1223
                        ? "La désinstallation est annulée : Windows a besoin de ton accord pour retirer Mindset.\n\nRelance-la et réponds « Oui » à la question de Windows."
                        : "La désinstallation ne peut pas démarrer : " + e.Message;
                    MessageBox.Show(m, "Désinstaller Mindset", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                return 2;
            }
        }

        // 2. La copie temporaire : c'est elle qui travaille (ce fichier-ci doit pouvoir être supprimé)
        if (!o.Copie)
        {
            try
            {
                string dossier = Path.Combine(Path.GetFullPath(lieux.Temp), "Mindset-desinstallation-" + Guid.NewGuid().ToString("N").Substring(0, 8));
                Directory.CreateDirectory(dossier);
                // Protégé : un programme sans droits ne peut pas y glisser un fichier qu'une copie administrateur chargerait
                if (!lieux.Test) ProtegerDossier(dossier);
                string copie = Path.Combine(dossier, Path.GetFileName(moi));
                File.Copy(moi, copie);
                StringBuilder a = new StringBuilder();
                foreach (string x in args) a.Append(Citer(x)).Append(' ');
                a.Append("-Copie -Original ").Append(Citer(moi)).Append(" -AttendrePid ").Append(Process.GetCurrentProcess().Id);
                ProcessStartInfo psi = new ProcessStartInfo(copie, a.ToString());
                psi.UseShellExecute = false; psi.WorkingDirectory = Environment.SystemDirectory;
                Process.Start(psi);
                return 0;
            }
            catch { o.Original = moi; }   // (copie impossible : on travaille d'ici, ce fichier restera)
        }
        if (o.AttendrePid > 0)
        {
            try { Process.GetProcessById(o.AttendrePid).WaitForExit(30000); } catch { }
        }

        Bilan b = new Bilan();
        b.FichierJournal = Path.Combine(Path.GetFullPath(lieux.Temp), "Mindset-desinstallation.txt");
        b.Journal("Désinstallation de Mindset" + (o.Nettoyer ? " (nettoyage de secours)" : "") + (lieux.Test ? " [test]" : ""));
        Travail t = new Travail(lieux, b, o.Original);
        int code;
        if (o.Nettoyer || (o.Silencieux && o.EssaiFenetre < 0))
        {
            t.Executer(o.SupprimerDonnees);
            code = b.Restes.Count == 0 ? 0 : 1;
            string texte = TexteBilan(t);
            Ecrire(o.Rapport, t, null, o.SupprimerDonnees, texte);
            if (!o.Silencieux) MessageBox.Show(texte, "Désinstaller Mindset", MessageBoxButtons.OK, b.Restes.Count == 0 ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
        }
        else
        {
            Fenetre f = new Fenetre(t, o.EssaiFenetre);
            Application.Run(f);
            code = f.Annule ? 2 : (b.Restes.Count == 0 ? 0 : 1);
            Ecrire(o.Rapport, t, f.CaseAuDepart, f.Annule ? false : f.DonneesDemandees, f.Annule ? "(annulé)" : f.TexteAffiche);
        }

        // La copie temporaire se supprime une fois finie (par l'invite de commandes, quelques secondes après)
        if (o.Copie) SupprimerCopie(moi);
        return code;
    }

    static bool EstAdmin()
    {
        return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
    }

    // Administrateurs et système seulement, sans hériter des droits du dossier temporaire de l'utilisateur
    static void ProtegerDossier(string dossier)
    {
        DirectorySecurity s = new DirectorySecurity();
        s.SetAccessRuleProtection(true, false);
        SecurityIdentifier admins = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
        s.SetOwner(admins);
        foreach (SecurityIdentifier id in new SecurityIdentifier[] { admins, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
            s.AddAccessRule(new FileSystemAccessRule(id, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        Directory.SetAccessControl(dossier, s);
    }

    static void SupprimerCopie(string copie)
    {
        string dossier = Path.GetDirectoryName(copie);
        if (!Path.GetFileName(dossier).StartsWith("Mindset-desinstallation-", StringComparison.OrdinalIgnoreCase)) return;
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe"),
                "/c ping -n 4 127.0.0.1 >nul & rd /s /q " + Citer(dossier));
            psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WorkingDirectory = Environment.SystemDirectory;
            Process.Start(psi);
        }
        catch { }
    }

    // Un argument entre guillemets, pour la ligne de commande d'un programme
    static string Citer(string s)
    {
        if (s.Length > 0 && s.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) return s;
        StringBuilder r = new StringBuilder("\"");
        int barres = 0;
        foreach (char c in s)
        {
            if (c == '\\') { barres++; continue; }
            if (c == '"') r.Append('\\', barres * 2 + 1).Append('"');
            else r.Append('\\', barres).Append(c);
            barres = 0;
        }
        r.Append('\\', barres * 2).Append('"');
        return r.ToString();
    }

    // Le texte du bilan, tel qu'il est affiché à la fin
    public static string TexteBilan(Travail t)
    {
        Bilan b = t.Bilan;
        StringBuilder s = new StringBuilder();
        if (b.Restes.Count == 0)
        {
            s.Append(b.Faits.Count == 0 ? "Il ne restait plus rien de Mindset sur ce PC." : "Mindset est désinstallé.");
            if (t.DonneesGardees.Count > 0)
            {
                string ou = string.Join(", ", t.DonneesGardees.ToArray());
                if (t.DonneesSupprimeesPar.Count == 0) s.Append("\r\n\r\nTes données sont gardées (" + ou + ") : si tu réinstalles Mindset, tu retrouveras tout.");
                else
                {
                    // (une ancienne version d'une appli a supprimé ses données malgré le choix : on le dit)
                    bool une = t.DonneesSupprimeesPar.Count == 1;
                    s.Append("\r\n\r\nTes données sont gardées (" + ou + "), sauf celles de " + string.Join(" et de ", t.DonneesSupprimeesPar.ToArray()) +
                             (une ? ", que son désinstalleur a supprimées" : ", que leurs désinstalleurs ont supprimées") +
                             ". Si tu réinstalles Mindset, tu retrouveras le reste.");
                }
            }
        }
        else
        {
            s.Append("Ces éléments n'ont pas pu être retirés :\r\n");
            foreach (string r in b.Restes) s.Append("  - ").Append(r).Append("\r\n");
            s.Append("\r\n").Append(t.ConseilRelance);
        }
        if (b.Alertes.Count > 0)
        {
            s.Append("\r\n\r\nÀ savoir :\r\n");
            foreach (string a in b.Alertes) s.Append("  - ").Append(a).Append("\r\n");
        }
        return s.ToString().TrimEnd();
    }

    static void Ecrire(string fichier, Travail t, object caseAuDepart, bool donnees, string texte)
    {
        if (string.IsNullOrEmpty(fichier)) return;
        try
        {
            Dictionary<string, object> r = new Dictionary<string, object>();
            r["ok"] = t.Bilan.Restes.Count == 0;
            r["faits"] = t.Bilan.Faits; r["restes"] = t.Bilan.Restes; r["alertes"] = t.Bilan.Alertes;
            r["caseDonneesAuDepart"] = caseAuDepart;
            r["donneesSupprimees"] = donnees;
            r["donneesSupprimeesPar"] = t.DonneesSupprimeesPar;
            r["texteAffiche"] = texte;
            string tmp = fichier + ".tmp";
            File.WriteAllText(tmp, new JavaScriptSerializer().Serialize(r), new UTF8Encoding(false));
            if (File.Exists(fichier)) File.Delete(fichier);
            File.Move(tmp, fichier);   // (le fichier n'apparaît qu'une fois complet)
        }
        catch { }
    }
}

// Le travail lui-même, étape par étape. Chaque étape regarde d'abord ce qui existe : ce qui est déjà parti est passé.
class Travail
{
    public Lieux Lieux;
    public Bilan Bilan;
    public string Garder;                                    // ce programme, s'il est dans un dossier des programmes
    public List<string> DonneesGardees = new List<string>();
    public List<string> DonneesSupprimeesPar = new List<string>();   // applis dont le désinstalleur a supprimé les données
    public string ConseilRelance = "";

    public Travail(Lieux l, Bilan b, string original)
    {
        Lieux = l; Bilan = b;
        if (!string.IsNullOrEmpty(original))
        {
            try
            {
                string g = Path.GetFullPath(original);
                foreach (string r in l.RacinesProgrammes()) if (Dans(g, r)) Garder = g;
            }
            catch { }
        }
    }

    static bool Dans(string chemin, string dossier)
    {
        return chemin.StartsWith(dossier.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);
    }

    public void Executer(bool supprimerDonnees)
    {
        List<string> programmes = Lieux.RacinesProgrammes();

        // 1. Mindset d'abord (il relancerait ses applis), puis le désinstalleur de chaque appli qui en a un, puis le reste
        Bilan.Etape("Fermeture de Mindset...");
        FermerProgrammes(programmes, "Mindset.exe");
        foreach (AppliGeree a in ApplisAvecDesinstalleur(programmes)) LancerDesinstalleur(a, supprimerDonnees);
        Bilan.Etape("Fermeture des applis...");
        FermerProgrammes(programmes, null);

        // 2. Les tâches planifiées (tout le dossier « \Mindset\ »)
        Bilan.Etape("Retrait des tâches planifiées...");
        SupprimerTaches();

        // 3. Le registre : HKLM\SOFTWARE\Mindset, et le lancement avec Windows
        Bilan.Etape("Nettoyage du registre...");
        SupprimerCle(Lieux.BaseMachine, Lieux.CleMindset);
        try
        {
            using (RegistryKey k = Lieux.BaseUtilisateur.OpenSubKey(Lieux.CleRun, true))
            {
                if (k != null && k.GetValue("Mindset") != null) { k.DeleteValue("Mindset", false); Bilan.Fait("Lancement avec Windows retiré"); }
            }
        }
        catch (Exception e) { Bilan.Reste("Le lancement de Mindset avec Windows (registre : " + e.Message + ")"); }

        // 4. Les raccourcis
        Bilan.Etape("Retrait des raccourcis...");
        foreach (string d in new string[] { Lieux.Bureau, Lieux.Menu })
        {
            if (string.IsNullOrEmpty(d)) continue;
            string l = Path.Combine(d, "Mindset.lnk");
            if (!File.Exists(l)) continue;
            try { File.SetAttributes(l, FileAttributes.Normal); File.Delete(l); Bilan.Fait("Raccourci retiré : " + l); }
            catch (Exception e) { Bilan.Reste("Le raccourci " + l + " (" + e.Message + ")"); }
        }

        // 5. Les données : toutes si c'est demandé, sinon seulement les téléchargements en cours de Mindset
        Bilan.Etape(supprimerDonnees ? "Suppression des données..." : "Rangement des données...");
        foreach (string d in Lieux.RacinesDonnees())
        {
            if (supprimerDonnees) { SupprimerDossier(d, "Le dossier des données " + d); continue; }
            SupprimerDossier(Path.Combine(d, @"Mindset\telechargements"), "Les téléchargements de Mindset (" + Path.Combine(d, @"Mindset\telechargements") + ")");
            string demande = Path.Combine(d, @"Mindset\installation.demande");
            try { if (File.Exists(demande)) File.Delete(demande); } catch { }
            DonneesGardees.Add(d);
        }

        // 6. Les programmes (sauf ce désinstalleur s'il est dedans : il part en dernier, si tout le reste est parti)
        Bilan.Etape("Suppression des programmes...");
        foreach (string r in programmes) SupprimerDossier(r, "Le dossier des programmes " + r);

        // 7. Fin : ce désinstalleur et l'entrée « Applications installées » partent seulement si rien d'autre ne reste
        //    (sinon ils restent, pour relancer la désinstallation après un redémarrage)
        Bilan.Etape("Derniers rangements...");
        if (Garder != null && File.Exists(Garder))
        {
            if (Bilan.Restes.Count == 0)
            {
                if (!SupprimerFichier(Garder)) Bilan.Reste("Le programme " + Garder);
                else
                {
                    // Ses dossiers devenus vides, jusqu'au dossier des programmes compris
                    foreach (string r in programmes)
                    {
                        if (!Dans(Garder, r)) continue;
                        string d = Path.GetDirectoryName(Garder);
                        while (d != null && (Dans(d, r) || string.Equals(d, r, StringComparison.OrdinalIgnoreCase)))
                        {
                            SupprimerDossier(d, "Le dossier des programmes " + d);
                            d = Path.GetDirectoryName(d);
                        }
                    }
                }
            }
        }
        // X:\Mindset : retiré s'il est vide (il garde Donnees si les données sont gardées)
        foreach (string disque in Lieux.Disques)
        {
            string m;
            try { m = Path.GetFullPath(Path.Combine(disque, "Mindset")); } catch { continue; }
            if (!Directory.Exists(m)) continue;
            string[] contenu;
            try { contenu = Directory.GetFileSystemEntries(m); } catch { continue; }
            if (contenu.Length == 0) SupprimerDossier(m, "Le dossier " + m);
            else if (supprimerDonnees && !Directory.Exists(Path.Combine(m, "Programmes")) && !Directory.Exists(Path.Combine(m, "Donnees")))
                Bilan.Reste("Le dossier " + m + " (il contient d'autres fichiers, qui ne viennent pas de Mindset : regarde-les avant de le supprimer)");
        }

        bool desinstalleurGarde = Garder != null && File.Exists(Garder);
        if (Bilan.Restes.Count == 0 || !desinstalleurGarde)
        {
            SupprimerCle(Lieux.BaseMachine, Lieux.CleDesinstall);
            ConseilRelance = "Redémarre l'ordinateur, puis relance ce programme (Desinstaller Mindset.exe) pour retirer le reste.";
        }
        else
        {
            // L'entrée « Applications installées » reste, et lance ce désinstalleur (même celle d'une ancienne version)
            try
            {
                using (RegistryKey k = Lieux.BaseMachine.OpenSubKey(Lieux.CleDesinstall, true))
                {
                    if (k != null) k.SetValue("UninstallString", "\"" + Garder + "\"");
                }
            }
            catch { }
            ConseilRelance = "Redémarre l'ordinateur, puis relance la désinstallation de Mindset (Paramètres de Windows, « Applications installées ») pour retirer le reste.";
        }
    }

    // -------------------------------------------------------------------------------------------------------------------
    // Programmes ouverts
    // -------------------------------------------------------------------------------------------------------------------
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(int acces, bool heriter, int pid);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder nom, ref int taille);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);

    static string CheminProcessus(int pid)
    {
        IntPtr h = OpenProcess(0x1000, false, pid);   // (PROCESS_QUERY_LIMITED_INFORMATION)
        if (h == IntPtr.Zero) return null;
        try
        {
            StringBuilder sb = new StringBuilder(1024);
            int n = sb.Capacity;
            return QueryFullProcessImageName(h, 0, sb, ref n) ? sb.ToString() : null;
        }
        finally { CloseHandle(h); }
    }

    // Ferme les programmes lancés depuis les dossiers des programmes de Mindset (seulement ceux-là : une copie de travail
    // ou de test du même nom, ailleurs, n'est jamais touchée). $Nom : seulement ce programme-là.
    void FermerProgrammes(List<string> racines, string nom)
    {
        int moi = Process.GetCurrentProcess().Id;
        foreach (Process p in Process.GetProcesses())
        {
            try
            {
                if (p.Id == moi) continue;
                string c = CheminProcessus(p.Id);
                if (c == null) continue;
                c = Path.GetFullPath(c);
                if (nom != null && !string.Equals(Path.GetFileName(c), nom, StringComparison.OrdinalIgnoreCase)) continue;
                bool dedans = false;
                foreach (string r in racines) if (Dans(c, r)) dedans = true;
                if (!dedans) continue;
                p.Kill();
                p.WaitForExit(5000);
                Bilan.Fait("Programme fermé : " + c);
            }
            catch (Exception e) { Bilan.Journal("Fermeture impossible (" + p.Id + ") : " + e.Message); }
        }
    }

    // -------------------------------------------------------------------------------------------------------------------
    // Les applis qui ont leur propre désinstalleur : celles de apps.json (champ « desinstalleur »), et, si apps.json est
    // absent ou abîmé, un « ...sinstaller <Appli>.exe » trouvé dans le dossier d'une appli
    // -------------------------------------------------------------------------------------------------------------------
    static readonly Regex NomFichier = new Regex(@"^[^\\/:*?""<>|]+$");

    List<AppliGeree> ApplisAvecDesinstalleur(List<string> racines)
    {
        List<AppliGeree> r = new List<AppliGeree>();
        foreach (string racine in racines)
        {
            try
            {
                string json = Path.Combine(racine, @"Mindset\fichiers\apps.json");
                if (File.Exists(json))
                {
                    object[] liste = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(json, Encoding.UTF8)) as object[];
                    if (liste != null)
                    {
                        foreach (object x in liste)
                        {
                            Dictionary<string, object> a = x as Dictionary<string, object>;
                            if (a == null) continue;
                            string nom = Texte(a, "nom"), exe = Texte(a, "exe"), des = Texte(a, "desinstalleur");
                            if (nom == null || des == null || exe == null) continue;
                            if (!NomFichier.IsMatch(nom) || nom.Contains("..") || !NomFichier.IsMatch(exe) || !NomFichier.IsMatch(des) || !des.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) continue;
                            string dossier = Path.Combine(racine, nom);
                            if (File.Exists(Path.Combine(dossier, des))) r.Add(new AppliGeree { Nom = nom, Dossier = dossier, Exe = exe, Desinstalleur = des });
                        }
                    }
                }
            }
            catch (Exception e) { Bilan.Journal("apps.json illisible dans " + racine + " : " + e.Message); }
            try
            {
                foreach (string dossier in Directory.GetDirectories(racine))
                {
                    if (string.Equals(Path.GetFileName(dossier), "Mindset", StringComparison.OrdinalIgnoreCase)) continue;
                    if ((File.GetAttributes(dossier) & FileAttributes.ReparsePoint) != 0) continue;
                    if (r.Exists(x => string.Equals(x.Dossier, dossier, StringComparison.OrdinalIgnoreCase))) continue;
                    foreach (string f in Directory.GetFiles(dossier, "*sinstaller *.exe"))
                    {
                        r.Add(new AppliGeree { Nom = Path.GetFileName(dossier), Dossier = dossier, Desinstalleur = Path.GetFileName(f) });
                        break;
                    }
                }
            }
            catch { }
        }
        return r;
    }

    static string Texte(Dictionary<string, object> d, string cle)
    {
        object v;
        return d.TryGetValue(cle, out v) ? v as string : null;
    }

    // Les dossiers de données d'une appli qui ont quelque chose dedans (<racine des données>\<Appli>)
    List<string> DossiersDonneesPleins(AppliGeree a)
    {
        List<string> r = new List<string>();
        foreach (string racine in Lieux.RacinesDonnees())
        {
            try
            {
                string d = Path.Combine(racine, a.Nom);
                if (Directory.Exists(d) && Directory.GetFileSystemEntries(d).Length > 0) r.Add(d);
            }
            catch { }
        }
        return r;
    }

    // Lance le désinstalleur de l'appli et attend sa fin (10 minutes au plus). Il a réussi si le programme de l'appli
    // n'est plus là (ou, sans programme connu, s'il a fini sans erreur). Sinon la désinstallation continue quand même.
    // Il reçoit le choix de la case (-GarderDonnees ou -SupprimerDonnees) : il ne pose pas la question. Données à garder
    // mais parties quand même (ancienne version de l'appli, qui ignore ce choix) : noté, pour que le bilan dise la vérité.
    void LancerDesinstalleur(AppliGeree a, bool supprimerDonnees)
    {
        string exeAppli = a.Exe != null ? Path.Combine(a.Dossier, a.Exe) : null;
        if (exeAppli != null && !File.Exists(exeAppli)) return;   // (déjà désinstallée : ses restes partent avec le dossier)
        Bilan.Etape("Désinstallation de " + a.Nom + " (suis les étapes de son désinstalleur)...");
        List<string> donneesAvant = supprimerDonnees ? new List<string>() : DossiersDonneesPleins(a);
        DateTime limite = DateTime.Now.AddMinutes(10);
        Process p;
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(Path.Combine(a.Dossier, a.Desinstalleur), supprimerDonnees ? "-SupprimerDonnees" : "-GarderDonnees");
            psi.UseShellExecute = false; psi.WorkingDirectory = a.Dossier;
            p = Process.Start(psi);
        }
        catch (Exception e)
        {
            Bilan.Alerte("Le désinstalleur de " + a.Nom + " n'a pas pu se lancer (" + e.Message + ") : ses fichiers sont retirés quand même, mais les réglages de Windows qu'il avait changés sont peut-être restés.");
            return;
        }
        if (!p.WaitForExit((int)(limite - DateTime.Now).TotalMilliseconds))
        {
            Bilan.Alerte("Le désinstalleur de " + a.Nom + " n'avait pas fini au bout de 10 minutes : ses fichiers sont retirés quand même, mais les réglages de Windows qu'il avait changés sont peut-être restés.");
            return;
        }
        int code = p.ExitCode;
        bool ok;
        if (exeAppli != null)
        {
            // Il a pu se relancer depuis une copie (comme celui-ci) : on attend tant qu'un programme du même nom tourne
            string nomProc = Path.GetFileNameWithoutExtension(a.Desinstalleur);
            DateTime grace = DateTime.Now.AddSeconds(3);
            while (File.Exists(exeAppli) && DateTime.Now < limite)
            {
                bool tourne = false;
                try { tourne = Process.GetProcessesByName(nomProc).Length > 0; } catch { }
                if (tourne) grace = DateTime.Now.AddSeconds(3);
                else if (DateTime.Now > grace) break;
                Thread.Sleep(300);
            }
            ok = !File.Exists(exeAppli);
        }
        else ok = code == 0;
        if (donneesAvant.Count > 0)
        {
            List<string> encore = DossiersDonneesPleins(a);
            if (!donneesAvant.TrueForAll(d => encore.Exists(x => string.Equals(x, d, StringComparison.OrdinalIgnoreCase))))
            {
                DonneesSupprimeesPar.Add(a.Nom);
                Bilan.Fait("Données de " + a.Nom + " supprimées par son désinstalleur (malgré le choix de les garder)");
            }
        }
        if (ok) Bilan.Fait(a.Nom + " désinstallé par son désinstalleur");
        else Bilan.Alerte("Le désinstalleur de " + a.Nom + " n'a pas fini (annulé, ou en erreur" + (code != 0 ? " : code " + code : "") + ") : ses fichiers sont retirés quand même, mais les réglages de Windows qu'il avait changés sont peut-être restés.");
    }

    // -------------------------------------------------------------------------------------------------------------------
    // Tâches planifiées : tout le dossier (ses tâches, même cachées, et ses sous-dossiers), puis le dossier lui-même
    // -------------------------------------------------------------------------------------------------------------------
    static bool Absent(Exception e)
    {
        int hr = Marshal.GetHRForException(e);
        return hr == unchecked((int)0x80070002) || hr == unchecked((int)0x80070003);
    }

    void SupprimerTaches()
    {
        string chemin = Lieux.DossierTaches;
        dynamic service, dossier;
        try { service = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service")); service.Connect(); }
        catch (Exception e) { Bilan.Reste("Les tâches planifiées de Mindset (dossier « " + chemin + " » du Planificateur de tâches : " + e.Message + ")"); return; }
        try { dossier = service.GetFolder(chemin); }
        catch (Exception e)
        {
            if (!Absent(e)) Bilan.Reste("Les tâches planifiées de Mindset (dossier « " + chemin + " » : " + e.Message + ")");
            return;
        }
        if (!ViderDossierTaches(dossier)) return;
        try
        {
            dynamic racine = service.GetFolder("\\");
            racine.DeleteFolder(chemin.TrimStart('\\'), 0);
            Bilan.Fait("Dossier de tâches planifiées retiré : " + chemin);
        }
        catch (Exception e) { if (!Absent(e)) Bilan.Reste("Le dossier « " + chemin + " » du Planificateur de tâches (" + e.Message + ")"); }
    }

    bool ViderDossierTaches(dynamic dossier)
    {
        bool tout = true;
        List<dynamic> sous = new List<dynamic>();
        foreach (dynamic s in dossier.GetFolders(0)) sous.Add(s);
        foreach (dynamic s in sous)
        {
            if (!ViderDossierTaches(s)) { tout = false; continue; }
            string nom = s.Name, p = s.Path;
            try { dossier.DeleteFolder(nom, 0); }
            catch (Exception e) { if (!Absent(e)) { tout = false; Bilan.Reste("Le dossier « " + p + " » du Planificateur de tâches (" + e.Message + ")"); } }
        }
        List<dynamic> taches = new List<dynamic>();
        foreach (dynamic t in dossier.GetTasks(1)) taches.Add(t);   // (1 : avec les tâches cachées)
        foreach (dynamic t in taches)
        {
            string nom = t.Name, p = t.Path;
            try { if ((int)t.State == 4) t.Stop(0); } catch { }    // (4 : en cours)
            try { dossier.DeleteTask(nom, 0); Bilan.Fait("Tâche planifiée retirée : " + p); }
            catch (Exception e) { if (!Absent(e)) { tout = false; Bilan.Reste("La tâche planifiée « " + p + " » (" + e.Message + ")"); } }
        }
        return tout;
    }

    // -------------------------------------------------------------------------------------------------------------------
    // Registre et fichiers
    // -------------------------------------------------------------------------------------------------------------------
    void SupprimerCle(RegistryKey baseCle, string cle)
    {
        try
        {
            using (RegistryKey k = baseCle.OpenSubKey(cle)) { if (k == null) return; }
            baseCle.DeleteSubKeyTree(cle, false);
            Bilan.Fait("Clé du registre retirée : " + baseCle.Name + "\\" + cle);
        }
        catch (Exception e) { Bilan.Reste("La clé du registre " + baseCle.Name + "\\" + cle + " (" + e.Message + ")"); }
    }

    bool SupprimerFichier(string f)
    {
        DateTime limite = DateTime.Now.AddSeconds(3);
        while (true)
        {
            try { if (!File.Exists(f)) return true; File.SetAttributes(f, FileAttributes.Normal); File.Delete(f); return true; }
            catch { if (DateTime.Now > limite) return false; Thread.Sleep(300); }
        }
    }

    // Supprime un dossier avec tout son contenu, en réessayant pendant 3 secondes (un programme qui vient d'être fermé
    // libère ses fichiers un peu après). Un lien (point de jonction, lien symbolique) est retiré lui-même, sans jamais
    // entrer dedans : ce vers quoi il pointe n'est pas touché. Ce désinstalleur ($Garder) est laissé à sa place.
    void SupprimerDossier(string dossier, string description)
    {
        if (!Directory.Exists(dossier)) return;
        DateTime limite = DateTime.Now.AddSeconds(3);
        string bloque;
        while (true)
        {
            bloque = null;
            SupprimerUneFois(dossier, ref bloque);
            if (bloque == null || DateTime.Now > limite) break;
            Thread.Sleep(300);
        }
        if (bloque == null) { Bilan.Fait(description + " : supprimé"); return; }
        Bilan.Reste(description + " (un fichier est peut-être encore ouvert : " + bloque + ")");
    }

    // $Bloque : le premier élément qui n'a pas pu être supprimé (null si tout est parti, à part ce désinstalleur)
    void SupprimerUneFois(string d, ref string bloque)
    {
        DirectoryInfo di = new DirectoryInfo(d);
        if (!di.Exists) return;
        try
        {
            if ((di.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                if ((di.Attributes & FileAttributes.ReadOnly) != 0) di.Attributes &= ~FileAttributes.ReadOnly;
                Directory.Delete(d, false);
                return;
            }
        }
        catch { if (bloque == null) bloque = d; return; }
        FileSystemInfo[] contenu;
        try { contenu = di.GetFileSystemInfos(); }
        catch { if (bloque == null) bloque = d; return; }
        bool garde = false;
        foreach (FileSystemInfo e in contenu)
        {
            if (e is DirectoryInfo)
            {
                SupprimerUneFois(e.FullName, ref bloque);
                if (Garder != null && Dans(Garder, e.FullName) && Directory.Exists(e.FullName)) garde = true;
                continue;
            }
            if (Garder != null && string.Equals(Path.GetFullPath(e.FullName), Garder, StringComparison.OrdinalIgnoreCase)) { garde = true; continue; }
            try
            {
                if ((e.Attributes & FileAttributes.ReadOnly) != 0) e.Attributes = FileAttributes.Normal;
                File.Delete(e.FullName);
            }
            catch { if (bloque == null) bloque = e.FullName; }
        }
        if (garde || bloque != null) return;
        try
        {
            if ((di.Attributes & FileAttributes.ReadOnly) != 0) di.Attributes &= ~FileAttributes.ReadOnly;
            Directory.Delete(d, false);
        }
        catch { if (bloque == null) bloque = d; }
    }
}

// La fenêtre « Désinstaller Mindset » : une question, une case (décochée), puis le bilan
class Fenetre : Form
{
    readonly Travail travail;
    readonly int essai;
    readonly Label titre, texte, attention, etape;
    readonly CheckBox caseDonnees;
    readonly ProgressBar barre;
    readonly TextBox bilan;
    readonly Button btnOui, btnNon, btnFermer;
    public bool CaseAuDepart, DonneesDemandees, Annule = true;
    public string TexteAffiche = "";

    public Fenetre(Travail t, int essai)
    {
        travail = t; this.essai = essai;
        Text = "Désinstaller Mindset";
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        Font = new Font("Segoe UI", 10f);
        AutoScaleMode = AutoScaleMode.Font;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false; MinimizeBox = false;
        BackColor = Color.White;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(560, 330);
        if (essai >= 0)
        {
            // Essai automatique : hors de l'écran, sans prendre la main, pas dans la barre des tâches
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-10000, -10000);
            ShowInTaskbar = false;
        }

        FlowLayoutPanel p = new FlowLayoutPanel();
        p.FlowDirection = FlowDirection.TopDown; p.WrapContents = false; p.Dock = DockStyle.Fill; p.Padding = new Padding(22, 18, 22, 10);
        p.AutoScroll = true;
        Controls.Add(p);
        int largeur = 510;

        titre = new Label { Text = "Désinstaller Mindset", Font = new Font("Segoe UI", 15f, FontStyle.Bold), AutoSize = true, Margin = new Padding(0, 0, 0, 10) };
        texte = new Label
        {
            AutoSize = true, MaximumSize = new Size(largeur, 0), Margin = new Padding(0, 0, 0, 14),
            Text = "Mindset va être retiré de ce PC, avec les applis qu'il a installées (Nevermind, Evermind...) : " +
                   "les programmes, les raccourcis et le lancement avec Windows.\r\n\r\n" +
                   "Tes données sont gardées : si tu réinstalles Mindset plus tard, tu retrouveras tout."
        };
        caseDonnees = new CheckBox { Text = "Supprimer aussi mes données (réglages, rendez-vous, sauvegardes)", AutoSize = true, Checked = false, Margin = new Padding(0, 0, 0, 4) };
        attention = new Label { Text = "Attention : tes données seront effacées pour de bon.", ForeColor = Color.FromArgb(176, 0, 32), AutoSize = true, Visible = false, Margin = new Padding(18, 0, 0, 0) };
        caseDonnees.CheckedChanged += delegate { attention.Visible = caseDonnees.Checked; };
        etape = new Label { AutoSize = true, MaximumSize = new Size(largeur, 0), Visible = false, Margin = new Padding(0, 6, 0, 8) };
        barre = new ProgressBar { Style = ProgressBarStyle.Marquee, Width = largeur, Height = 14, Visible = false };
        bilan = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Width = largeur, Height = 170, Visible = false, BackColor = Color.White, BorderStyle = BorderStyle.None };

        FlowLayoutPanel boutons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, Width = largeur, Height = 44, Margin = new Padding(0, 18, 0, 0) };
        btnNon = new Button { Text = "Annuler", AutoSize = true, MinimumSize = new Size(110, 32) };
        btnOui = new Button { Text = "Désinstaller", AutoSize = true, MinimumSize = new Size(110, 32) };
        btnFermer = new Button { Text = "Fermer", AutoSize = true, MinimumSize = new Size(110, 32), Visible = false };
        btnNon.Click += delegate { Close(); };
        btnOui.Click += delegate { Lancer(); };
        btnFermer.Click += delegate { Close(); };
        boutons.Controls.AddRange(new Control[] { btnFermer, btnNon, btnOui });

        p.Controls.AddRange(new Control[] { titre, texte, caseDonnees, attention, etape, barre, bilan, boutons });
        CancelButton = btnNon;
        ActiveControl = btnNon;   // (Entrée par erreur = Annuler)
        CaseAuDepart = caseDonnees.Checked;

        Shown += delegate
        {
            if (essai < 0) return;
            if (essai == 1) caseDonnees.Checked = true;
            Lancer();
        };
        FormClosing += delegate(object s, FormClosingEventArgs e) { if (enCours) e.Cancel = true; };   // (pas de fermeture au milieu)
    }

    protected override bool ShowWithoutActivation { get { return essai >= 0; } }

    bool enCours;
    void Lancer()
    {
        Annule = false; enCours = true;
        DonneesDemandees = caseDonnees.Checked;
        caseDonnees.Visible = false; attention.Visible = false; btnOui.Visible = false; btnNon.Visible = false;
        texte.Text = "Mindset est en train d'être retiré. Si une appli ouvre son propre désinstalleur, suis ses étapes.";
        etape.Visible = true; barre.Visible = true;
        travail.Bilan.SurEtape = delegate(string t) { try { BeginInvoke((MethodInvoker)delegate { etape.Text = t; }); } catch { } };
        Thread fil = new Thread(delegate()
        {
            try { travail.Executer(DonneesDemandees); }
            catch (Exception e) { travail.Bilan.Reste("La désinstallation s'est arrêtée à cause d'une erreur : " + e.Message); }
            try { BeginInvoke((MethodInvoker)Fini); } catch { }
        });
        fil.IsBackground = true;
        fil.Start();
    }

    void Fini()
    {
        enCours = false;
        bool ok = travail.Bilan.Restes.Count == 0;
        titre.Text = ok ? "Mindset est désinstallé" : "Désinstallation pas tout à fait finie";
        etape.Visible = false; barre.Visible = false;
        TexteAffiche = Desinstalleur.TexteBilan(travail);
        texte.Text = ok ? "C'est fini. Merci d'avoir utilisé Mindset !" : "Presque tout est retiré, mais il reste quelques éléments :";
        bilan.Text = TexteAffiche;
        bilan.Visible = true;
        // Des restes ou des choses à savoir : la fenêtre s'agrandit pour tout montrer
        if (!ok || travail.Bilan.Alertes.Count > 0) { bilan.Height = 250; ClientSize = new Size(ClientSize.Width, 450); }
        btnFermer.Visible = true;
        AcceptButton = btnFermer; CancelButton = btnFermer;
        btnFermer.Focus();
        if (essai >= 0)
        {
            System.Windows.Forms.Timer t = new System.Windows.Forms.Timer { Interval = 300 };
            t.Tick += delegate { t.Stop(); Close(); };
            t.Start();
        }
    }
}
