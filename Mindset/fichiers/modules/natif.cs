// Mindset : fonctions de Windows appelées directement (barre de titre sombre, identité dans la barre des tâches).
using System;
using System.Runtime.InteropServices;

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
}
