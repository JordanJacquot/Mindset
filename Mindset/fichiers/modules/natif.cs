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
