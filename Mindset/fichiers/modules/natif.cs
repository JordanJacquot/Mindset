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
