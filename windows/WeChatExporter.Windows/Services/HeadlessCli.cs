using System.IO;
using System.Reflection;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using WeChatExporter.Models;

namespace WeChatExporter.Services;

/// <summary>
/// 无头 CLI（SPEC §7）：本可执行文件支持 `wce <subcmd>` 分支，不启动 GUI。
///   wce --auto-sync                    跑一次定时增量（读 settings.json 设置）
///   wce search &lt;kw&gt; [--dir &lt;导出根&gt;]  无头搜索，stdout 打印前 20 条
///   wce index [--dir &lt;导出根&gt;]         重建搜索索引
///   wce report [--dir &lt;导出根&gt;]        重生成年度报告+日历
///   wce --version / wce --help
/// 退出码：0 成功；1 运行失败；2 参数/文件错误。
/// 与 macOS Services/HeadlessCLI.swift 对称实现。
/// </summary>
public static class HeadlessCli
{
    public const string SubCommand = "wce";
    private static readonly TimeZoneInfo Shanghai = TimeZoneInfo.FindSystemTimeZoneById("China Standard Time");

    /// <summary>命令行是否为 wce 无头模式（首参 == "wce"）。</summary>
    public static bool ShouldRun(string[] args) => args.Length > 0 && args[0] == SubCommand;

    /// <summary>在 App.OnStartup 中调用：同步跑完无头任务后返回退出码。</summary>
    public static int Run(string[] args)
    {
        // args[0] == "wce"
        var rest = args.Skip(1).ToArray();
        return rest.FirstOrDefault() switch
        {
            "--auto-sync" => RunAutoSync(),
            "search" => RunSearch(rest),
            "index" => RunIndex(rest),
            "report" => RunReport(rest),
            "--version" or "version" => PrintVersion(),
            "--help" or "help" or "-h" => PrintUsage(),
            null => PrintUsage(2),
            var other => Unknown(other!),
        };
    }

    private static int PrintVersion()
    {
        Console.WriteLine($"WeChatExporter {CurrentVersion()} (headless {SubCommand})");
        return 0;
    }

    private static string CurrentVersion()
    {
        var info = Assembly.GetExecutingAssembly()
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (string.IsNullOrWhiteSpace(info)) return "2.19.2";
        var plus = info.IndexOf('+');
        return plus >= 0 ? info[..plus] : info;
    }

    private static int PrintUsage(int code = 0)
    {
        Console.WriteLine("""
        WeChatExporter headless CLI（wce）
          wce --auto-sync                    跑一次定时增量导出（读设置，日志 → %LocalAppData%/WCE/autosync.log）
          wce search <关键词> [--dir <导出根>]  全文搜索（前 20 条，stdout）
          wce index [--dir <导出根>]          重建 wce-search.sqlite 索引
          wce report [--dir <导出根>]         重生成年度报告 + 日历事件
          wce --version / wce --help

        参数说明：
          --dir  指定导出根目录；缺省用最近一次导出目录（设置项 export.lastDir），
                 再缺省 %USERPROFILE%/Downloads/微信聊天记录导出
        """);
        return code;
    }

    private static int Unknown(string cmd)
    {
        Console.Error.WriteLine($"未知子命令：{cmd}");
        return PrintUsage(2);
    }

    // MARK: - 目录解析

    private static string ResolveDir(string[] rest)
    {
        for (var i = 0; i < rest.Length - 1; i++)
        {
            if (rest[i] == "--dir") return ExpandTilde(rest[i + 1]);
        }
        var last = AppSettings.LastExportDir;
        if (!string.IsNullOrWhiteSpace(last) && Directory.Exists(ExpandTilde(last)))
            return ExpandTilde(last);
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Downloads", "微信聊天记录导出");
    }

    private static string ExpandTilde(string p) =>
        p.StartsWith('~') ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), p.TrimStart('~', '/', '\\')) : p;

    // MARK: - auto-sync

    private static int RunAutoSync()
    {
        void Log(string line)
        {
            AutoSyncScheduler.AppendRunLog(line);
            Console.WriteLine(line);
        }

        if (!AppSettings.AutoSyncEnabled)
        {
            Log("auto-sync skipped: export.autoSync.enabled=false");
            return 0;
        }

        var dir = string.IsNullOrWhiteSpace(AppSettings.AutoSyncExportDir)
            ? AppSettings.LastExportDir
            : AppSettings.AutoSyncExportDir;
        if (string.IsNullOrWhiteSpace(dir))
        {
            AutoSyncScheduler.AppendRunLog("auto-sync failed: 未配置导出目录");
            return 1;
        }
        var baseDir = ExpandTilde(dir);

        var wxCli = WxCliService.TryCreate();
        if (wxCli is null)
        {
            AutoSyncScheduler.AppendRunLog("auto-sync failed: 找不到 wx-cli（内置/系统均未找到）");
            return 1;
        }

        // wx-cli 环境检查（key ✅ 且缓存可用）
        bool prepared;
        try { prepared = wxCli.IsPreparedForQueryAsync().GetAwaiter().GetResult(); }
        catch { prepared = false; }
        if (!prepared)
        {
            AutoSyncScheduler.AppendRunLog("auto-sync skipped: wx-cli 未就绪（密钥/缓存不可用），先运行一次 GUI「准备数据」");
            return 0;
        }

        // 会话列表（子集过滤）
        var subset = ParseContactIDs(AppSettings.AutoSyncContactIDs);
        IReadOnlyList<ContactItem> contacts;
        try { contacts = wxCli.LoadSessionsAsync(_ => { }).GetAwaiter().GetResult(); }
        catch (Exception ex)
        {
            AutoSyncScheduler.AppendRunLog($"auto-sync failed: 会话加载失败（{ex.Message}）");
            return 1;
        }
        var targets = subset.Count == 0
            ? contacts
            : contacts.Where(c => subset.Contains(c.Id)).ToList();

        var totalKept = 0;
        var anyChange = false;

        foreach (var contact in targets)
        {
            var tempDir = Path.Combine(Path.GetTempPath(), $"WCE-autoSync-{Guid.NewGuid():N}");
            try
            {
                Directory.CreateDirectory(tempDir);
                var count = wxCli.ExportAsync(contact, tempDir, false, _ => { }).GetAwaiter().GetResult();

                // 增量游标（与 GUI 同口径）
                var lastTs = IncrementalExport.LoadCursor(contact.Id, baseDir);
                if (lastTs is { } after)
                {
                    count = IncrementalExport.FilterArtifacts(tempDir, contact.Id, after, null);
                    if (count == 0)
                    {
                        AutoSyncScheduler.AppendRunLog($"no-change {contact.DisplayName}（{contact.Id}）");
                        continue;
                    }
                    var maxTs = IncrementalExport.MaxTimestamp(tempDir);
                    if (maxTs > after)
                        IncrementalExport.SaveCursor(contact.Id, baseDir, maxTs);
                }
                else
                {
                    IncrementalExport.SaveCursor(contact.Id, baseDir, IncrementalExport.MaxTimestamp(tempDir));
                }

                // 复制文字产物到 base/<会话名>/
                var contactDir = Path.Combine(baseDir, ExportArtifacts.SanitizeDirName(contact.DisplayName));
                ExportArtifacts.CopyTextArtifacts(tempDir, contactDir);
                totalKept += count;
                anyChange = true;
                AutoSyncScheduler.AppendRunLog($"changed {contact.DisplayName}：{count} 条新增");
            }
            catch (Exception ex)
            {
                AutoSyncScheduler.AppendRunLog($"auto-sync {contact.DisplayName} 导出失败：{ex.Message}");
            }
            finally
            {
                try { if (Directory.Exists(tempDir)) Directory.Delete(tempDir, true); } catch { /* ignore */ }
            }
        }

        if (!anyChange)
        {
            AutoSyncScheduler.AppendRunLog("no-change（无新增，跳过后续产物）");
            AppSettings.AutoSyncLastRun = IsoNow();
            return 0;
        }

        // 后处理管线（顺序 SPEC §3：过滤 → 脱敏 → 索引 → 报告/日历 → 水印）
        if (AppSettings.FilterEnabled)
        {
            _ = ExportFilterService.Apply(baseDir, AppSettings.FilterFromDate, AppSettings.FilterToDate, AppSettings.FilterKeywords,
                line => AutoSyncScheduler.AppendRunLog("filter: " + line));
        }
        if (AppSettings.AnonEnabled)
        {
            var names = AnonymizationService.CollectNames(baseDir);
            _ = AnonymizationService.Anonymize(baseDir, names,
                new AnonymizationService.Settings(AppSettings.AnonMaskPii, AppSettings.AnonKeepMapping),
                line => AutoSyncScheduler.AppendRunLog("anon: " + line));
        }
        if (AppSettings.SearchIndexEnabled)
        {
            _ = SearchIndexService.Build(baseDir, AutoSyncScheduler.AppendRunLog);
        }
        if (AppSettings.AnnualReportEnabled)
        {
            _ = AnnualReportService.Write(baseDir, AutoSyncScheduler.AppendRunLog);
        }
        if (AppSettings.CalendarExtractEnabled)
        {
            _ = CalendarExtractService.Extract(baseDir, AutoSyncScheduler.AppendRunLog);
        }
        if (Watermark.Enabled)
        {
            Watermark.ApplyToDirectory(baseDir, AutoSyncScheduler.AppendRunLog);
        }

        AppSettings.AutoSyncLastRun = IsoNow();
        AutoSyncScheduler.AppendRunLog($"auto-sync done：{targets.Count} 个会话，共 {totalKept} 条新增");
        return 0;
    }

    private static HashSet<string> ParseContactIDs(string json)
    {
        var set = new HashSet<string>(StringComparer.Ordinal);
        try
        {
            var arr = JsonSerializer.Deserialize<string[]>(json);
            if (arr is not null)
                foreach (var s in arr) set.Add(s);
        }
        catch { /* ignore */ }
        return set;
    }

    // MARK: - search / index / report

    private static int RunSearch(string[] rest)
    {
        if (rest.Length < 2)
            return PrintUsage(2);
        var kw = rest[1];
        var dir = ResolveDir(rest);
        var indexPath = Path.Combine(dir, SearchIndexService.FileName);
        using var db = SearchIndexService.Open(indexPath);
        if (db is null)
        {
            Console.Error.WriteLine($"未找到搜索索引 {indexPath}，请先导出并开启「搜索索引」");
            return 2;
        }
        var hits = SearchIndexService.Query(db, kw, 20);
        if (hits.Count == 0)
        {
            Console.WriteLine($"（无命中：{kw}）");
            return 0;
        }
        foreach (var h in hits)
        {
            var time = h.Ts > 0
                ? TimeZoneInfo.ConvertTimeFromUtc(DateTimeOffset.FromUnixTimeSeconds(h.Ts).UtcDateTime, Shanghai).ToString("yyyy-MM-dd HH:mm")
                : "-";
            Console.WriteLine($"[{time}] {h.Chat} · {h.Sender}: {h.Snippet}");
        }
        return 0;
    }

    private static int RunIndex(string[] rest)
    {
        var dir = ResolveDir(rest);
        var count = SearchIndexService.Build(dir, Console.WriteLine);
        return count >= 0 ? 0 : 1;
    }

    private static int RunReport(string[] rest)
    {
        var dir = ResolveDir(rest);
        var ok = true;
        if (AnnualReportService.Write(dir, Console.WriteLine) is null) ok = false;
        if (CalendarExtractService.Extract(dir, Console.WriteLine) == 0) ok = false;
        return ok ? 0 : 1;
    }

    private static string IsoNow() => DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
}
