// Mindset : fonctions de Windows appelées directement (barre de titre sombre, identité dans la barre des tâches).
using System;
using System.Runtime.InteropServices;

// Les micros et les sorties audio du PC, par leur nom : les mêmes noms qu'Evermind (EMMicros, EMSortie), que Windows
// coupe à 31 lettres. C'est par ce nom que la suite garde son choix (les numéros changent quand on branche un appareil).
public static class MSAudio
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CAPSIN { public ushort mid, pid; public uint ver; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string name; public uint fmts; public ushort ch, res; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CAPSOUT { public ushort mid, pid; public uint ver; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string name; public uint fmts; public ushort ch, res; public uint support; }
    [DllImport("winmm.dll")] static extern uint waveInGetNumDevs();
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern int waveInGetDevCapsW(IntPtr id, ref CAPSIN c, int sz);
    [DllImport("winmm.dll")] static extern uint waveOutGetNumDevs();
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern int waveOutGetDevCapsW(IntPtr id, ref CAPSOUT c, int sz);

    public static string[] Micros()
    {
        uint n = waveInGetNumDevs(); string[] r = new string[n];
        for (uint d = 0; d < n; d++) { CAPSIN c = new CAPSIN(); waveInGetDevCapsW((IntPtr)d, ref c, Marshal.SizeOf(c)); r[d] = c.name ?? ""; }
        return r;
    }

    public static string[] Sorties()
    {
        uint n = waveOutGetNumDevs(); string[] r = new string[n];
        for (uint d = 0; d < n; d++) { CAPSOUT c = new CAPSOUT(); waveOutGetDevCapsW((IntPtr)d, ref c, Marshal.SizeOf(c)); r[d] = c.name ?? ""; }
        return r;
    }
}

// Affichage des applis dans Mindset : la vraie fenêtre de Nevermind ou d'Evermind devient une fenêtre enfant de la zone
// centrale de Mindset (sans bordure ni barre de titre), puis est rendue telle qu'elle était quand Mindset la libère.
// Chaque appli reste son propre programme : si elle plante, Mindset continue.
public static class MSIntegration
{
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetParent(IntPtr child, IntPtr parent);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr h);

    const int GWL_STYLE = -16, GWL_EXSTYLE = -20;
    const long WS_CHILD = 0x40000000, WS_POPUP = 0x80000000, WS_CAPTION = 0x00C00000, WS_THICKFRAME = 0x00040000,
               WS_SYSMENU = 0x00080000, WS_MINIMIZEBOX = 0x00020000, WS_MAXIMIZEBOX = 0x00010000, WS_VISIBLE = 0x10000000;
    const long WS_EX_APPWINDOW = 0x00040000, WS_EX_WINDOWEDGE = 0x100, WS_EX_DLGMODALFRAME = 0x1, WS_EX_CLIENTEDGE = 0x200, WS_EX_STATICEDGE = 0x20000;
    const uint SWP_NOZORDER = 0x4, SWP_FRAMECHANGED = 0x20, SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40, SWP_NOMOVE = 0x2, SWP_NOSIZE = 0x1;

    // La fenêtre principale d'un programme : une fenêtre de premier niveau de ce processus dont le titre est $Titre
    // (visible ou cachée près de l'horloge), à l'exclusion des fenêtres « possédées » (alertes, menus).
    public static IntPtr Trouver(int pid, string titre)
    {
        IntPtr trouve = IntPtr.Zero;
        EnumWindows(delegate (IntPtr h, IntPtr l)
        {
            int p; GetWindowThreadProcessId(h, out p);
            if (p != pid || GetWindow(h, 4) != IntPtr.Zero) return true;   // 4 = GW_OWNER
            var t = new System.Text.StringBuilder(256); GetWindowText(h, t, 256);
            var c = new System.Text.StringBuilder(256); GetClassName(h, c, 256);
            if (t.ToString() == titre && c.ToString().StartsWith("HwndWrapper")) { trouve = h; return false; }
            return true;
        }, IntPtr.Zero);
        return trouve;
    }

    public static int Processus(IntPtr h) { int p; GetWindowThreadProcessId(h, out p); return p; }
    public static bool EstEnfantDe(IntPtr h, IntPtr parent) { return GetParent(h) == parent; }

    // Accroche la fenêtre dans $Parent ; renvoie ses styles d'avant (pour la rendre telle quelle), ou 0 si Windows refuse
    // (par exemple : une appli en administrateur dans un Mindset qui ne l'est pas)
    public static long[] Accrocher(IntPtr fenetre, IntPtr parent, int largeur, int hauteur)
    {
        long style = GetWindowLongPtr(fenetre, GWL_STYLE).ToInt64();
        long ex = GetWindowLongPtr(fenetre, GWL_EXSTYLE).ToInt64();
        ShowWindow(fenetre, 9);   // SW_RESTORE : ni réduite, ni agrandie
        long nouveau = (style & ~(WS_POPUP | WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX)) | WS_CHILD | WS_VISIBLE;
        long nouveauEx = ex & ~(WS_EX_APPWINDOW | WS_EX_WINDOWEDGE | WS_EX_DLGMODALFRAME | WS_EX_CLIENTEDGE | WS_EX_STATICEDGE);
        SetWindowLongPtr(fenetre, GWL_STYLE, new IntPtr(nouveau));
        SetWindowLongPtr(fenetre, GWL_EXSTYLE, new IntPtr(nouveauEx));
        if (SetParent(fenetre, parent) == IntPtr.Zero && Marshal.GetLastWin32Error() != 0)
        {
            SetWindowLongPtr(fenetre, GWL_STYLE, new IntPtr(style));
            SetWindowLongPtr(fenetre, GWL_EXSTYLE, new IntPtr(ex));
            return null;
        }
        SetWindowPos(fenetre, IntPtr.Zero, 0, 0, largeur, hauteur, SWP_NOZORDER | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
        return new long[] { style, ex };
    }

    public static void Redimensionner(IntPtr fenetre, int largeur, int hauteur)
    {
        SetWindowPos(fenetre, IntPtr.Zero, 0, 0, largeur, hauteur, SWP_NOZORDER | SWP_NOACTIVATE);
    }

    public static void Focus(IntPtr fenetre) { SetFocus(fenetre); }

    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);

    // L'appli s'est cachée elle-même (réduite près de l'horloge) ? Son propre drapeau « visible », pas celui de ses
    // parents : quand Mindset se cache, la fenêtre accrochée ne compte pas comme cachée.
    // L'appli affichée a sa propre barre (Menu, Fermer) : propriété « Mindset.BarrePropre » posée sur sa fenêtre
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetProp(IntPtr h, string nom);
    public static bool BarrePropre(IntPtr fenetre) { return fenetre != IntPtr.Zero && GetProp(fenetre, "Mindset.BarrePropre") != IntPtr.Zero; }

    public static bool EstMontree(IntPtr fenetre) { return (GetWindowLongPtr(fenetre, GWL_STYLE).ToInt64() & WS_VISIBLE) != 0; }

    // Demande à l'appli de se fermer, comme un clic sur sa croix (elle applique sa propre règle : demander, réduire, quitter)
    public static void Fermer(IntPtr fenetre) { PostMessage(fenetre, 0x0010, IntPtr.Zero, IntPtr.Zero); }   // WM_CLOSE

    // Rend la fenêtre telle qu'elle était et l'affiche (« Ouvrir dans sa fenêtre »)
    public static void Detacher(IntPtr fenetre, long style, long ex)
    {
        Liberer(fenetre, style, ex);
        ShowWindow(fenetre, 9);   // SW_RESTORE
    }

    // Rend la fenêtre telle qu'elle était, cachée (l'appli reste près de l'horloge)
    public static void Liberer(IntPtr fenetre, long style, long ex)
    {
        if (!IsWindow(fenetre)) return;
        ShowWindow(fenetre, 0);   // SW_HIDE
        SetParent(fenetre, IntPtr.Zero);
        SetWindowLongPtr(fenetre, GWL_STYLE, new IntPtr(style & ~WS_VISIBLE));
        SetWindowLongPtr(fenetre, GWL_EXSTYLE, new IntPtr(ex));
        SetWindowPos(fenetre, IntPtr.Zero, 0, 0, 0, 0, SWP_NOZORDER | SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED | SWP_NOACTIVATE);
    }
}

// Lancer un programme SANS les droits administrateur depuis un Mindset administrateur : avec le jeton de l'Explorateur
// (qui tourne toujours avec les droits de l'utilisateur). Evermind et les liens ne doivent jamais hériter des droits admin.
public static class MSLanceur
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO { public int cb; public string reserved, desktop, title; public int x, y, w, h, xc, yc, attr, flags; public short show, r2; public IntPtr r3, stdin, stdout, stderr; }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr process, thread; public int pid, tid; }
    [DllImport("user32.dll")] static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint acces, bool herite, int pid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr p, uint acces, out IntPtr jeton);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool DuplicateTokenEx(IntPtr j, uint acces, IntPtr attr, int niveau, int type, out IntPtr nouveau);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessWithTokenW(IntPtr jeton, int logon, string appli, System.Text.StringBuilder ligne, int flags, IntPtr env, string dossier, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    // Renvoie le numéro du processus lancé (lève une exception si Windows refuse)
    public static int SansAdmin(string exe, string arguments, string dossier)
    {
        IntPtr shell = GetShellWindow();
        if (shell == IntPtr.Zero) throw new InvalidOperationException("Explorateur introuvable");
        int pidShell; GetWindowThreadProcessId(shell, out pidShell);
        IntPtr proc = OpenProcess(0x1000, false, pidShell);   // PROCESS_QUERY_LIMITED_INFORMATION
        if (proc == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        IntPtr jeton = IntPtr.Zero, primaire = IntPtr.Zero;
        try
        {
            if (!OpenProcessToken(proc, 0x0002, out jeton)) throw new System.ComponentModel.Win32Exception();   // TOKEN_DUPLICATE
            if (!DuplicateTokenEx(jeton, 0x02000000, IntPtr.Zero, 2, 1, out primaire)) throw new System.ComponentModel.Win32Exception();   // MAXIMUM_ALLOWED, impersonation, primaire
            var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si);
            PROCESS_INFORMATION pi;
            var ligne = new System.Text.StringBuilder("\"" + exe + "\"" + (string.IsNullOrEmpty(arguments) ? "" : " " + arguments));
            if (!CreateProcessWithTokenW(primaire, 0, exe, ligne, 0, IntPtr.Zero, dossier, ref si, out pi)) throw new System.ComponentModel.Win32Exception();
            CloseHandle(pi.thread); CloseHandle(pi.process);
            return pi.pid;
        }
        finally
        {
            if (primaire != IntPtr.Zero) CloseHandle(primaire);
            if (jeton != IntPtr.Zero) CloseHandle(jeton);
            CloseHandle(proc);
        }
    }
}

public static class MSNative
{
    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

    // Barre de titre sombre (Windows 10 2004+) et de la couleur du fond (Windows 11), couleur en 0xBBGGRR
    public static void SetDarkTitleBar(IntPtr hwnd, int color)
    {
        int on = 1;
        DwmSetWindowAttribute(hwnd, 20, ref on, 4);
        DwmSetWindowAttribute(hwnd, 35, ref color, 4);
    }

    // Mindset apparaît sous son propre nom dans la barre des tâches, pas comme PowerShell
    public static void SetAppId(string appId) { SetCurrentProcessExplicitAppUserModelID(appId); }

    // Autorise une autre appli (réveillée par Mindset) à passer au premier plan
    [DllImport("user32.dll")]
    public static extern bool AllowSetForegroundWindow(int pid);

    // -----------------------------------------------------------------------
    // Identité de la fenêtre dans la barre des tâches : son icône, et ce que Windows relance quand on l'épingle
    // (sinon l'épingle relancerait PowerShell, avec son icône). Même principe que Nevermind et Evermind.
    // -----------------------------------------------------------------------
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct PROPERTYKEY { public Guid fmtid; public uint pid; }

    // PROPVARIANT réduit à ce qui sert ici : une chaîne (VT_LPWSTR)
    [StructLayout(LayoutKind.Explicit)]
    struct PROPVARIANT
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr p;
        [FieldOffset(8)] public long pad1;
        [FieldOffset(16)] public long pad2;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out PROPERTYKEY key);
        void GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
        void SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);
        void Commit();
    }

    [DllImport("shell32.dll", PreserveSig = false)]
    static extern void SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

    static readonly Guid AppUserModelKeys = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

    static void SetString(IPropertyStore store, uint pid, string value)
    {
        PROPERTYKEY key = new PROPERTYKEY { fmtid = AppUserModelKeys, pid = pid };
        PROPVARIANT v = new PROPVARIANT { vt = 31, p = Marshal.StringToCoTaskMemUni(value) };   // 31 = VT_LPWSTR
        try { store.SetValue(ref key, ref v); }
        finally { Marshal.FreeCoTaskMem(v.p); }
    }

    public static void SetWindowIdentity(IntPtr hwnd, string appId, string relaunchCommand, string iconPath, string name)
    {
        Guid iid = typeof(IPropertyStore).GUID;
        IPropertyStore store;
        SHGetPropertyStoreForWindow(hwnd, ref iid, out store);
        try
        {
            SetString(store, 2, relaunchCommand);   // System.AppUserModel.RelaunchCommand
            SetString(store, 3, iconPath);          // System.AppUserModel.RelaunchIconResource
            SetString(store, 4, name);              // System.AppUserModel.RelaunchDisplayNameResource
            SetString(store, 5, appId);             // System.AppUserModel.ID, en dernier
            store.Commit();
        }
        finally { Marshal.ReleaseComObject(store); }
    }
}

// Raccourcis du menu Démarrer qui portent l'identité d'une appli (System.AppUserModel.ID), voir installations.ps1.
// L'hôte de chaque appli s'appelle Mindset.exe : pour nommer son bouton dans la barre des tâches, Windows cherche un
// raccourci du menu Démarrer de la même identité et prend son nom ; sans lui, il prend la description du programme
// (« Mindset » pour toutes). WScript.Shell ne sait pas écrire cette identité : le raccourci est écrit ici.
public static class MSRaccourci
{
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    class ShellLink { }

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder file, int cch, IntPtr findData, uint flags);
        void GetIDList(out IntPtr pidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder name, int cch);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder dir, int cch);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder args, int cch);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int showCmd);
        void SetShowCmd(int showCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder iconPath, int cch, out int icon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string iconPath, int icon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pathRel, int reserved);
        void Resolve(IntPtr hwnd, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct PROPERTYKEY { public Guid fmtid; public uint pid; }

    [StructLayout(LayoutKind.Explicit)]
    struct PROPVARIANT
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr p;
        [FieldOffset(8)] public long pad1;
        [FieldOffset(16)] public long pad2;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out PROPERTYKEY key);
        void GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
        void SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);
        void Commit();
    }

    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PROPVARIANT pv);

    // PKEY_AppUserModel_ID : {9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}, 5
    static PROPERTYKEY CleAppId() { return new PROPERTYKEY { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 }; }

    // Écrit (ou remplace) le raccourci : programme, dossier de travail, icône (index 0), commentaire et identité
    public static void Ecrire(string lien, string cible, string dossier, string icone, string description, string appId)
    {
        object o = new ShellLink();
        try
        {
            IShellLinkW l = (IShellLinkW)o;
            l.SetPath(cible);
            l.SetArguments("");
            l.SetWorkingDirectory(dossier ?? "");
            l.SetIconLocation(icone ?? cible, 0);
            l.SetDescription(description ?? "");
            IPropertyStore store = (IPropertyStore)o;
            PROPERTYKEY k = CleAppId();
            PROPVARIANT v = new PROPVARIANT { vt = 31, p = Marshal.StringToCoTaskMemUni(appId) };   // 31 = VT_LPWSTR
            try { store.SetValue(ref k, ref v); store.Commit(); }
            finally { Marshal.FreeCoTaskMem(v.p); }
            ((System.Runtime.InteropServices.ComTypes.IPersistFile)o).Save(lien, true);
        }
        finally { Marshal.ReleaseComObject(o); }
    }

    // Ce que contient un raccourci : { programme, "icône,index", identité } (identité vide s'il n'en a pas)
    public static string[] Lire(string lien)
    {
        object o = new ShellLink();
        try
        {
            ((System.Runtime.InteropServices.ComTypes.IPersistFile)o).Load(lien, 0);   // STGM_READ
            IShellLinkW l = (IShellLinkW)o;
            var cible = new System.Text.StringBuilder(1024);
            l.GetPath(cible, cible.Capacity, IntPtr.Zero, 4);   // SLGP_RAWPATH
            var icone = new System.Text.StringBuilder(1024);
            int index;
            l.GetIconLocation(icone, icone.Capacity, out index);
            string appId = "";
            IPropertyStore store = (IPropertyStore)o;
            PROPERTYKEY k = CleAppId();
            PROPVARIANT v;
            store.GetValue(ref k, out v);
            try { if (v.vt == 31 && v.p != IntPtr.Zero) appId = Marshal.PtrToStringUni(v.p); }
            finally { PropVariantClear(ref v); }
            return new string[] { cible.ToString(), icone.ToString() + "," + index, appId };
        }
        finally { Marshal.ReleaseComObject(o); }
    }
}

// Mises à jour automatiques : depuis combien de temps personne ne touche au PC, et si un jeu ou une vidéo est en plein écran
public static class MSActivite
{
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [StructLayout(LayoutKind.Sequential)] struct RECTA { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFOA { public int cbSize; public RECTA rcMonitor, rcWork; public uint dwFlags; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECTA r);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFOA i);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);

    public static double SecondesInactif()
    {
        var l = new LASTINPUTINFO(); l.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref l)) return 0;
        return unchecked((uint)Environment.TickCount - l.dwTime) / 1000.0;
    }

    // La fenêtre de devant couvre tout son écran (jeu, vidéo, présentation), et ce n'est pas le Bureau
    public static bool PleinEcranDevant()
    {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero || h == GetShellWindow() || h == GetDesktopWindow()) return false;
        var c = new System.Text.StringBuilder(64); GetClassName(h, c, 64);
        string cl = c.ToString();
        if (cl == "Progman" || cl == "WorkerW" || cl == "Shell_TrayWnd") return false;
        RECTA r; if (!GetWindowRect(h, out r)) return false;
        var mi = new MONITORINFOA(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOA));
        if (!GetMonitorInfo(MonitorFromWindow(h, 2), ref mi)) return false;
        return r.Left <= mi.rcMonitor.Left && r.Top <= mi.rcMonitor.Top && r.Right >= mi.rcMonitor.Right && r.Bottom >= mi.rcMonitor.Bottom;
    }
}

// Les programmes de la suite qui tournent, trouvés par leur CHEMIN (jamais par leur nom : l'hôte de chaque appli s'appelle
// Mindset.exe, comme Mindset lui-même), et ce qu'ils consomment (Paramètres > Consommation).
// Tout part du relevé des processus de Windows (NtQuerySystemInformation) : il donne pour chacun son nom, sa mémoire et son
// temps de processeur sans rien ouvrir, même pour un programme lancé en administrateur. Le chemin (et pour WebView2 la ligne
// de commande) se lit avec le droit le plus faible (PROCESS_QUERY_LIMITED_INFORMATION), une seule fois par processus
// (gardé en mémoire tant qu'il tourne).
public static class MSProcessus
{
    [StructLayout(LayoutKind.Sequential)]
    struct InfoProcessus
    {
        public uint Suivant; public uint Fils;
        public long PriveWS; public uint Defauts; public uint FilsMax; public ulong Cycles;
        public long Creation; public long TempsUtilisateur; public long TempsNoyau;
        public ushort NomLongueur; public ushort NomMax; public IntPtr Nom;
        public int Priorite; public IntPtr Pid; public IntPtr Parent;
    }
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int classe, IntPtr tampon, int taille, out int requis);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int classe, IntPtr tampon, int taille, out int requis);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int acces, bool herite, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, System.Text.StringBuilder s, ref int n);

    public class Processus { public int Pid; public string Nom; public long Memoire; public long Temps; public long Creation; }

    // Tous les processus du PC, en un seul appel
    public static System.Collections.Generic.List<Processus> Releve()
    {
        var r = new System.Collections.Generic.List<Processus>();
        int taille = 512 * 1024;
        for (int essai = 0; essai < 6; essai++)
        {
            IntPtr t = Marshal.AllocHGlobal(taille);
            try
            {
                int requis;
                int s = NtQuerySystemInformation(5, t, taille, out requis);   // (SystemProcessInformation)
                if (s == unchecked((int)0xC0000004)) { taille = Math.Max(taille * 2, requis + 64 * 1024); continue; }
                if (s != 0) return r;
                long o = 0;
                while (true)
                {
                    IntPtr p = new IntPtr(t.ToInt64() + o);
                    var i = (InfoProcessus)Marshal.PtrToStructure(p, typeof(InfoProcessus));
                    int pid = i.Pid.ToInt32();
                    if (pid != 0)
                        r.Add(new Processus { Pid = pid, Nom = i.Nom == IntPtr.Zero ? "" : Marshal.PtrToStringUni(i.Nom, i.NomLongueur / 2),
                            Memoire = i.PriveWS, Temps = i.TempsUtilisateur + i.TempsNoyau, Creation = i.Creation });
                    if (i.Suivant == 0) break;
                    o += i.Suivant;
                }
                return r;
            }
            finally { Marshal.FreeHGlobal(t); }
        }
        return r;
    }

    static readonly System.Collections.Generic.Dictionary<string, string> chemins = new System.Collections.Generic.Dictionary<string, string>();
    static readonly System.Collections.Generic.Dictionary<string, string> commandes = new System.Collections.Generic.Dictionary<string, string>();

    // Le chemin complet du programme d'un processus (null si Windows refuse : processus protégé, ou déjà terminé)
    public static string Chemin(int pid)
    {
        IntPtr h = OpenProcess(0x1000, false, pid);   // (PROCESS_QUERY_LIMITED_INFORMATION)
        if (h == IntPtr.Zero) return null;
        try
        {
            var s = new System.Text.StringBuilder(1024); int n = s.Capacity;
            return QueryFullProcessImageName(h, 0, s, ref n) ? s.ToString() : null;
        }
        finally { CloseHandle(h); }
    }

    // La ligne de commande d'un processus (null si Windows refuse)
    public static string LigneCommande(int pid)
    {
        IntPtr h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) return null;
        try
        {
            int requis;
            NtQueryInformationProcess(h, 60, IntPtr.Zero, 0, out requis);   // (ProcessCommandLineInformation : la taille d'abord)
            if (requis <= 0 || requis > 1024 * 1024) return null;
            IntPtr t = Marshal.AllocHGlobal(requis);
            try
            {
                if (NtQueryInformationProcess(h, 60, t, requis, out requis) != 0) return null;
                int longueur = Marshal.ReadInt16(t) & 0xFFFF;
                IntPtr texte = Marshal.ReadIntPtr(t, IntPtr.Size);   // (UNICODE_STRING : Length, MaximumLength, puis Buffer aligné)
                return texte == IntPtr.Zero ? "" : Marshal.PtrToStringUni(texte, longueur / 2);
            }
            finally { Marshal.FreeHGlobal(t); }
        }
        finally { CloseHandle(h); }
    }

    static string Cle(Processus p) { return p.Pid + ":" + p.Creation; }
    static string CheminGarde(Processus p)
    {
        string k = Cle(p), c;
        if (chemins.TryGetValue(k, out c)) return c;
        c = Chemin(p.Pid);
        if (c != null) { try { c = System.IO.Path.GetFullPath(c); } catch { } }
        chemins[k] = c;
        return c;
    }
    static string CommandeGardee(Processus p)
    {
        string k = Cle(p), c;
        if (commandes.TryGetValue(k, out c)) return c;
        c = LigneCommande(p.Pid);
        commandes[k] = c;
        return c;
    }
    // (les processus terminés sont oubliés)
    static void Oublier(System.Collections.Generic.List<Processus> liste)
    {
        var vivants = new System.Collections.Generic.HashSet<string>();
        foreach (var p in liste) vivants.Add(Cle(p));
        foreach (var d in new[] { chemins, commandes })
        {
            var morts = new System.Collections.Generic.List<string>();
            foreach (string k in d.Keys) if (!vivants.Contains(k)) morts.Add(k);
            foreach (string k in morts) d.Remove(k);
        }
    }

    static string Dossier(string d)
    {
        if (string.IsNullOrEmpty(d)) return null;
        try { return System.IO.Path.GetFullPath(d).TrimEnd('\\') + "\\"; } catch { return null; }
    }
    public static bool Dans(string chemin, string dossier)
    {
        string d = Dossier(dossier);
        return chemin != null && d != null && chemin.StartsWith(d, StringComparison.OrdinalIgnoreCase);
    }

    // Les processus lancés depuis ce dossier (sous-dossiers compris). noms : seulement ces programmes-là, directement dans
    // le dossier. Jamais le processus « exclu » (Mindset lui-même), ni un programme du dossier « interdit » (celui de Mindset).
    public static int[] DansDossier(string dossier, string[] noms, int exclu, string interdit)
    {
        var r = new System.Collections.Generic.List<int>();
        string d = Dossier(dossier);
        if (d == null) return r.ToArray();
        var liste = Releve();
        Oublier(liste);
        foreach (var p in liste)
        {
            if (p.Pid == exclu) continue;
            if (noms != null && Array.FindIndex(noms, n => string.Equals(n, p.Nom, StringComparison.OrdinalIgnoreCase)) < 0) continue;
            string c = CheminGarde(p);
            if (c == null || !c.StartsWith(d, StringComparison.OrdinalIgnoreCase)) continue;
            if (noms != null && !string.Equals(System.IO.Path.GetDirectoryName(c).TrimEnd('\\') + "\\", d, StringComparison.OrdinalIgnoreCase)) continue;
            if (Dans(c, interdit)) continue;
            r.Add(p.Pid);
        }
        return r.ToArray();
    }

    // Les chemins des programmes qui tournent sous ces noms de fichier (pour trouver une copie d'une appli déjà ouverte :
    // son dossier est ensuite vérifié comme les autres)
    public static string[] Chemins(string[] noms)
    {
        var r = new System.Collections.Generic.List<string>();
        var liste = Releve();
        Oublier(liste);
        foreach (var p in liste)
        {
            if (Array.FindIndex(noms, n => string.Equals(n, p.Nom, StringComparison.OrdinalIgnoreCase)) < 0) continue;
            string c = CheminGarde(p);
            if (c != null && !r.Contains(c)) r.Add(c);
        }
        return r.ToArray();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Ce que consomme la suite, par partie : Mindset (le processus « moi » et les programmes de son dossier), chaque partie
    // de « dossiers » (dans l'ordre : le premier dossier qui contient le programme l'emporte), et WebView2 (les
    // msedgewebview2.exe dont la ligne de commande contient un des « marqueurs », les dossiers de données WebView2 de la
    // suite). Le processeur : en % de tout le PC depuis la mesure précédente (0 à la première).
    // ---------------------------------------------------------------------------------------------------------------
    public class Partie { public string Nom; public int Nombre; public long Memoire; public double Processeur; }
    static System.Collections.Generic.Dictionary<string, long> tempsAvant = new System.Collections.Generic.Dictionary<string, long>();
    static long horlogeAvant;

    public static Partie[] Mesurer(int moi, string nomMoi, string dossierMoi, string[] noms, string[] dossiers, string nomWebView, string[] marqueurs)
    {
        var parties = new System.Collections.Generic.List<Partie>();
        var index = new System.Collections.Generic.Dictionary<string, Partie>();
        Func<string, Partie> partie = n => { Partie x; if (!index.TryGetValue(n, out x)) { x = new Partie { Nom = n }; index[n] = x; parties.Add(x); } return x; };
        partie(nomMoi);
        foreach (string n in noms) partie(n);
        partie(nomWebView);
        string[] ds = Array.ConvertAll(dossiers, Dossier);
        string dm = Dossier(dossierMoi);

        var liste = Releve();
        long horloge = DateTime.UtcNow.Ticks;
        Oublier(liste);
        var temps = new System.Collections.Generic.Dictionary<string, long>();
        double ecoule = horlogeAvant > 0 ? (double)(horloge - horlogeAvant) * Environment.ProcessorCount : 0;
        foreach (var p in liste)
        {
            string nom = null;
            if (p.Pid == moi) nom = nomMoi;
            else if (string.Equals(p.Nom, "msedgewebview2.exe", StringComparison.OrdinalIgnoreCase))
            {
                string cmd = CommandeGardee(p);
                if (cmd != null) foreach (string m in marqueurs) if (!string.IsNullOrEmpty(m) && cmd.IndexOf(m, StringComparison.OrdinalIgnoreCase) >= 0) { nom = nomWebView; break; }
            }
            else
            {
                string c = CheminGarde(p);
                if (c != null)
                {
                    if (dm != null && c.StartsWith(dm, StringComparison.OrdinalIgnoreCase)) nom = nomMoi;
                    else for (int i = 0; i < ds.Length; i++) if (ds[i] != null && c.StartsWith(ds[i], StringComparison.OrdinalIgnoreCase)) { nom = noms[i]; break; }
                }
            }
            if (nom == null) continue;
            Partie x = partie(nom);
            x.Nombre++; x.Memoire += p.Memoire;
            string k = Cle(p); long avant;
            temps[k] = p.Temps;
            if (ecoule > 0 && tempsAvant.TryGetValue(k, out avant) && p.Temps >= avant) x.Processeur += (p.Temps - avant) / ecoule * 100.0;
        }
        tempsAvant = temps; horlogeAvant = horloge;
        return parties.ToArray();
    }
}
