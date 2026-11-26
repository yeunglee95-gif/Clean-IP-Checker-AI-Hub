// AIHub.exe - the doorbell for the AI Hub.
//
// Why this exists: powershell.exe is a console program, so Windows creates a
// console window for it before any script can ask for it to be hidden. Hiding
// it afterwards leaves a real console that can still be seen and closed, and
// closing it takes the hub down with it.
//
// This is a GUI-subsystem program. It never has a console, and it starts
// PowerShell with CREATE_NO_WINDOW, so no console window is ever created and
// there is nothing to close by accident.
//
// It also reports its own failure instead of vanishing: a missing script or a
// refused process start puts a message box on screen.
//
// Built with:
//   csc /target:winexe /optimize+ /out:AIHub.exe Launcher.cs

using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

class Launcher
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBox(IntPtr hWnd, string text, string caption, uint type);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

    const uint MB_ICONERROR = 0x10;

    static void Fail(string message)
    {
        MessageBox(IntPtr.Zero, message, "AI Hub", MB_ICONERROR);
    }

    [STAThread]
    static int Main()
    {
        // Same identity as the shortcuts and the hub process, so Windows groups
        // the launcher, the window and the pin as one app.
        try { SetCurrentProcessExplicitAppUserModelID("Geniotek.AIHub"); } catch { }

        string dir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        string script = Path.Combine(dir, "Start-AIHub.ps1");
        if (!File.Exists(script))
        {
            Fail("Start-AIHub.ps1 is missing next to AIHub.exe:\n\n" + dir +
                 "\n\nRestore the launcher folder before starting AI Hub.");
            return 2;
        }

        string ps = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            @"WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(ps))
        {
            Fail("Windows PowerShell was not found at:\n\n" + ps);
            return 3;
        }

        try
        {
            var psi = new ProcessStartInfo();
            psi.FileName = ps;
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\"";
            psi.WorkingDirectory = dir;
            psi.UseShellExecute = false;   // required for CreateNoWindow to be honoured
            psi.CreateNoWindow = true;     // CREATE_NO_WINDOW: no console window exists
            psi.WindowStyle = ProcessWindowStyle.Hidden;

            Process.Start(psi);
            return 0;
        }
        catch (Exception ex)
        {
            Fail("AI Hub could not start:\n\n" + ex.Message);
            return 4;
        }
    }
}
