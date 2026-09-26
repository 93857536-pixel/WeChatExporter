using System.Diagnostics;
using System.IO;
using System.Text;

namespace WeChatExporter.Services;

/// <summary>
/// 定时增量导出（SPEC §2）：Windows 用 schtasks 计划任务。
/// 安装 = schtasks /Create /SC MINUTE /MO n /TN "WCE AutoSync" /TR "&lt;exe&gt; wce --auto-sync"；
/// 卸载 = schtasks /Delete /TN "WCE AutoSync"。日志 → %LocalAppData%/WCE/autosync.log。
/// 与 macOS Services/AutoSyncScheduler.swift 对称实现。
/// </summary>
public static class AutoSyncScheduler
{
    public const string TaskName = "WCE AutoSync";

    private static string LogPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "WCE", "autosync.log");

    public static bool IsInstalled
    {
        get
        {
            try
            {
                var r = Run("schtasks", $"/Query /TN \"{TaskName}\"");
                return r.ExitCode == 0;
            }
            catch
            {
                return false;
            }
        }
    }

    /// <summary>安装/更新定时任务。返回安装成功与否。</summary>
    public static bool Install(int intervalMinutes, string exportDir, string contactIDsJson, Action<string>? log)
    {
        var minutes = Math.Max(5, intervalMinutes);
        var dir = string.IsNullOrWhiteSpace(exportDir) ? AppSettings.LastExportDir : exportDir;
        var exe = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(exe))
        {
            log?.Invoke("定时任务安装失败：找不到可执行文件路径");
            return false;
        }

        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
        }
        catch { /* ignore */ }

        // 若已存在先删再建（/Create 直接建，同名会失败）
        try { Run("schtasks", $"/Delete /TN \"{TaskName}\" /F"); } catch { /* ignore */ }

        // /TR 中参数需转义；用引号包 exe 路径，参数直接拼接
        var taskRun = $"\"{exe}\" wce --auto-sync";
        var create = Run("schtasks",
            $"/Create /SC MINUTE /MO {minutes} /TN \"{TaskName}\" /TR \"{taskRun}\" /F");
        if (create.ExitCode != 0)
        {
            log?.Invoke($"定时任务安装失败：schtasks 拒绝（exit {create.ExitCode}）：{create.Output.Trim()}");
            return false;
        }
        log?.Invoke($"定时任务已安装：每 {minutes} 分钟增量导出 → {(string.IsNullOrWhiteSpace(dir) ? "(默认导出目录)" : dir)}");
        return true;
    }

    public static void Uninstall(Action<string>? log)
    {
        if (IsInstalled)
        {
            var r = Run("schtasks", $"/Delete /TN \"{TaskName}\" /F");
            log?.Invoke(r.ExitCode == 0 ? "定时任务已卸载" : $"定时任务卸载失败：{r.Output.Trim()}");
        }
        else
        {
            log?.Invoke("定时任务未安装");
        }
    }

    /// <summary>追加一行运行日志（无头模式使用）。</summary>
    public static void AppendRunLog(string line)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
            var entry = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {line}{Environment.NewLine}";
            File.AppendAllText(LogPath, entry, new UTF8Encoding(false));
        }
        catch { /* 日志写入失败不影响任务 */ }
    }

    private sealed record RunResult(int ExitCode, string Output);

    private static RunResult Run(string fileName, string arguments)
    {
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        try
        {
            using var p = Process.Start(psi)!;
            var output = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
            p.WaitForExit(30_000);
            return new RunResult(p.HasExited ? p.ExitCode : -1, output);
        }
        catch (Exception ex)
        {
            return new RunResult(-1, ex.Message);
        }
    }
}
