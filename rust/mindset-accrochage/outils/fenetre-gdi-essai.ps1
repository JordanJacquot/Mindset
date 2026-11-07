# Une fenêtre Win32 d'essai pour l'accrochage, de classe HwndWrapper[...] (celle que Mindset cherche pour WPF), peinte
# en orange par GDI : « Café crème ». Lancée par essai-accrochage.ps1, SEULEMENT sur un bureau Windows à part. Son dessin
# se lit sur l'image de la fenêtre de Mindset (PrintWindow), contrairement à celui de WPF : c'est la preuve visuelle qu'une
# fenêtre classique d'un autre programme est bien PAR-DESSUS la page. Créée cachée ; rendue, elle reste cachée.
param([int]$Secondes = 150)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FenetreGdi
{
    delegate IntPtr Proc(IntPtr h, uint m, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASS { public uint style; public Proc proc; public int c1, c2; public IntPtr inst, icone, curseur, fond; public string menu, nom; }
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr h; public uint m; public IntPtr w, l; public uint t; public int x, y; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClassW(ref WNDCLASS c);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(uint ex, string classe, string titre, uint style, int x, int y, int l, int h, IntPtr p, IntPtr m, IntPtr i, IntPtr d);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern int GetMessageW(out MSG m, IntPtr h, uint a, uint b);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr SetTimer(IntPtr h, IntPtr id, uint ms, IntPtr f);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll")] static extern void PostQuitMessage(int c);
    [DllImport("gdi32.dll")] static extern IntPtr CreateSolidBrush(uint couleur);
    static Proc garde = Traiter;
    static DateTime fin;
    static IntPtr Traiter(IntPtr h, uint m, IntPtr w, IntPtr l)
    {
        if (m == 0x0113 && DateTime.Now > fin) { DestroyWindow(h); return IntPtr.Zero; }   // WM_TIMER
        if (m == 0x0002) { PostQuitMessage(0); return IntPtr.Zero; }                        // WM_DESTROY
        return DefWindowProcW(h, m, w, l);
    }
    public static void Lancer(string titre, int secondes)
    {
        fin = DateTime.Now.AddSeconds(secondes);
        var c = new WNDCLASS { proc = garde, nom = "HwndWrapper[cafe-creme;;essai]", fond = CreateSolidBrush(0x00008AFF) };
        RegisterClassW(ref c);
        IntPtr h = CreateWindowExW(0, c.nom, titre, 0x00CF0000, 60, 60, 640, 480, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        SetTimer(h, new IntPtr(1), 300, IntPtr.Zero);
        MSG msg;
        while (GetMessageW(out msg, IntPtr.Zero, 0, 0) > 0) { TranslateMessage(ref msg); DispatchMessageW(ref msg); }
    }
}
'@
[FenetreGdi]::Lancer('Café crème', $Secondes)
