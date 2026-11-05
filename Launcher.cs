// DeviceWidget.exe - trình mở ứng dụng (được biên dịch lúc cài đặt bằng csc.exe có sẵn trong Windows).
// Có tệp .exe thật thì Windows Search / Start Menu mới nhận Device Widget là một ứng dụng.
//  - Nếu widget đang chạy ngầm: báo cho nó hiện lên ngay (không phải chờ khởi động lại).
//  - Nếu chưa chạy: chạy DeviceWidget.ps1 bằng PowerShell, không hiện cửa sổ console.
//  - Tham số /hidden: chỉ chạy nền ở khay hệ thống (dùng khi chạy cùng Windows).
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;

[assembly: AssemblyTitle("Device Widget")]
[assembly: AssemblyProduct("Device Widget")]
[assembly: AssemblyDescription("Device Widget")]
[assembly: AssemblyVersion("1.2.0.0")]
[assembly: AssemblyFileVersion("1.2.0.0")]

static class Launcher
{
    [STAThread]
    static int Main(string[] args)
    {
        bool hidden = args.Length > 0 && args[0].Trim().ToLowerInvariant() == "/hidden";

        if (!hidden)
        {
            try
            {
                using (var ev = EventWaitHandle.OpenExisting(@"Local\DeviceStatusWidget.Show"))
                {
                    ev.Set();
                    return 0;
                }
            }
            catch { }
        }

        string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string ps1 = Path.Combine(dir, "DeviceWidget.ps1");
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                                 @"WindowsPowerShell\v1.0\powershell.exe");
        var psi = new ProcessStartInfo(ps,
            "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + ps1 + "\"" + (hidden ? " -Hidden" : ""));
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;
        Process.Start(psi);
        return 0;
    }
}
