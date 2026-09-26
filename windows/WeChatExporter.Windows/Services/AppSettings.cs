using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace WeChatExporter.Services;

/// <summary>
/// 应用设置（v2.19 新功能 + 既有项统一持久化）。
/// 与 Watermark / DiagnosticUploader 共用同一 settings.json
/// （%APPDATA%/WeChatExporter/settings.json），读取/写入均保留其他字段。
/// 设置键名与 macOS 端 UserDefaults 完全一致（见 docs/MULTIPLATFORM_SPEC.md）。
/// </summary>
public static class AppSettings
{
    private const string DirectoryName = "WeChatExporter";
    private const string FileName = "settings.json";

    private static string SettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        DirectoryName,
        FileName);

    // MARK: - 底层读写

    private static JsonObject Load()
    {
        try
        {
            if (File.Exists(SettingsPath))
                return JsonNode.Parse(File.ReadAllText(SettingsPath)) as JsonObject ?? new JsonObject();
        }
        catch { /* 解析失败按空设置处理 */ }
        return new JsonObject();
    }

    private static void Save(JsonObject obj)
    {
        try
        {
            var dir = Path.GetDirectoryName(SettingsPath)!;
            Directory.CreateDirectory(dir);
            File.WriteAllText(SettingsPath,
                obj.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { /* 设置写入失败不影响导出 */ }
    }

    private static string? GetString(string key)
    {
        var obj = Load();
        if (obj.TryGetPropertyValue(key, out var node) && node is JsonValue v && v.TryGetValue<string>(out var s))
            return s;
        return null;
    }

    private static bool GetBool(string key, bool fallback)
    {
        var obj = Load();
        if (obj.TryGetPropertyValue(key, out var node) && node is JsonValue v && v.TryGetValue<bool>(out var b))
            return b;
        return fallback;
    }

    private static int GetInt(string key, int fallback)
    {
        var obj = Load();
        if (obj.TryGetPropertyValue(key, out var node) && node is JsonValue v && v.TryGetValue<int>(out var n))
            return n;
        return fallback;
    }

    private static void Set(string key, object value)
    {
        var obj = Load();
        obj[key] = JsonValue.Create(value);
        Save(obj);
    }

    // MARK: - v2.19 设置项（键名与 macOS 完全一致）

    /// <summary>导出时在根目录生成 wce-search.sqlite 全文搜索索引（默认开启）。</summary>
    public static bool SearchIndexEnabled
    {
        get => GetBool("export.searchIndex", true);
        set => Set("export.searchIndex", value);
    }

    /// <summary>定时增量导出总开关（默认关闭）。</summary>
    public static bool AutoSyncEnabled
    {
        get => GetBool("export.autoSync.enabled", false);
        set => Set("export.autoSync.enabled", value);
    }

    /// <summary>定时间隔分钟数（默认 60，最小 5）。</summary>
    public static int AutoSyncIntervalMinutes
    {
        get => GetInt("export.autoSync.intervalMinutes", 60);
        set => Set("export.autoSync.intervalMinutes", value);
    }

    /// <summary>定时任务目标目录（默认=导出根目录）。</summary>
    public static string AutoSyncExportDir
    {
        get => GetString("export.autoSync.exportDir") ?? "";
        set => Set("export.autoSync.exportDir", value);
    }

    /// <summary>定时任务会话子集（JSON 数组字符串；空=全部）。</summary>
    public static string AutoSyncContactIDs
    {
        get => GetString("export.autoSync.contactIDs") ?? "[]";
        set => Set("export.autoSync.contactIDs", value);
    }

    /// <summary>上次定时运行时间（ISO 本地格式）。</summary>
    public static string AutoSyncLastRun
    {
        get => GetString("export.autoSync.lastRun") ?? "";
        set => Set("export.autoSync.lastRun", value);
    }

    /// <summary>脱敏导出总开关（默认关闭）。</summary>
    public static bool AnonEnabled
    {
        get => GetBool("export.anon.enabled", false);
        set => Set("export.anon.enabled", value);
    }

    /// <summary>脱敏时是否同时模糊化 PII（手机号/身份证/邮箱，默认开启）。</summary>
    public static bool AnonMaskPii
    {
        get => GetBool("export.anon.maskPii", true);
        set => Set("export.anon.maskPii", value);
    }

    /// <summary>脱敏后是否保留映射文件（可逆；关闭=导出后销毁）。</summary>
    public static bool AnonKeepMapping
    {
        get => GetBool("export.anon.keepMapping", true);
        set => Set("export.anon.keepMapping", value);
    }

    /// <summary>过滤导出总开关（默认关闭）。</summary>
    public static bool FilterEnabled
    {
        get => GetBool("export.filter.enabled", false);
        set => Set("export.filter.enabled", value);
    }

    /// <summary>过滤起始日期 yyyy-MM-dd（含；空=不限）。</summary>
    public static string FilterFromDate
    {
        get => GetString("export.filter.fromDate") ?? "";
        set => Set("export.filter.fromDate", value);
    }

    /// <summary>过滤结束日期 yyyy-MM-dd（含；空=不限）。</summary>
    public static string FilterToDate
    {
        get => GetString("export.filter.toDate") ?? "";
        set => Set("export.filter.toDate", value);
    }

    /// <summary>过滤关键词（逗号分隔，不区分大小写；空=不过滤内容）。</summary>
    public static string FilterKeywords
    {
        get => GetString("export.filter.keywords") ?? "";
        set => Set("export.filter.keywords", value);
    }

    /// <summary>生成年度可视化报告 HTML（默认开启）。</summary>
    public static bool AnnualReportEnabled
    {
        get => GetBool("export.annualReport", true);
        set => Set("export.annualReport", value);
    }

    /// <summary>提取日历事件 .ics/.json（默认开启）。</summary>
    public static bool CalendarExtractEnabled
    {
        get => GetBool("export.calendarExtract", true);
        set => Set("export.calendarExtract", value);
    }

    /// <summary>最近一次导出目录（搜索面板 / wce CLI 用它定位 wce-search.sqlite）。</summary>
    public static string LastExportDir
    {
        get => GetString("export.lastDir") ?? "";
        set => Set("export.lastDir", value);
    }
}
