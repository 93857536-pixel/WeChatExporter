using System.Diagnostics;
using System.Security.Principal;

namespace WeChatExporter.Services;

internal static class PlatformHelper
{
    public static bool IsRunningAsAdministrator()
    {
        if (!OperatingSystem.IsWindows())
            return false;
        using var identity = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(identity);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }

    public static bool TryRestartAsAdministrator()
    {
        if (!OperatingSystem.IsWindows() || IsRunningAsAdministrator())
            return false;

        var exe = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe))
            return false;

        Process.Start(new ProcessStartInfo
        {
            FileName = exe,
            UseShellExecute = true,
            Verb = "runas",
            WorkingDirectory = Environment.CurrentDirectory
        });
        return true;
    }
}
