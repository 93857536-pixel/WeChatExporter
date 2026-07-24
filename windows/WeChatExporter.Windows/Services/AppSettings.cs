using System.IO;
using System.Text.Json;
using WeChatExporter.Models;

namespace WeChatExporter.Services;

public enum AppearanceMode
{
    System,
    Light,
    Dark
}

public static class AppearanceModeInfo
{
    public static string Title(AppearanceMode mode) => mode switch
    {
        AppearanceMode.Light => "浅色",
        AppearanceMode.Dark => "深色",
        _ => "跟随系统"
    };
}

public enum DateRangePreset
{
    All,
    Last7Days,
    Last30Days,
    Last90Days,
    Last365Days,
    Custom
}

public static class DateRangePresetInfo
{
    public static string Title(DateRangePreset preset) => preset switch
    {
        DateRangePreset.Last7Days => "最近 7 天",
        DateRangePreset.Last30Days => "最近 30 天",
        DateRangePreset.Last90Days => "最近 90 天",
        DateRangePreset.Last365Days => "最近 1 年",
        DateRangePreset.Custom => "自定义",
        _ => "全部时间"
    };
}

/// <summary>应用设置（持久化到 %AppData%/WeChatExporter/settings.json）。</summary>
public sealed class AppSettings
{
    public const string CreditLine = "@林琝淏科技集团有限公司出品";

    private static readonly Lazy<AppSettings> SharedLazy = new(Load);
    public static AppSettings Shared => SharedLazy.Value;

    public AppearanceMode Appearance { get; set; } = AppearanceMode.System;
    public ExportStyle ExportStyle { get; set; } = ExportStyle.SingleHtml;
    public bool IncludeMedia { get; set; }
    public bool IncludeStickerGallery { get; set; } = true;
    public bool FolderIncludeCsv { get; set; } = true;
    public bool FolderIncludeJson { get; set; }
    public bool OpenFolderAfterExport { get; set; }
    public string ExportPath { get; set; } = DefaultExportPath();
    public DateRangePreset DateRangePreset { get; set; } = DateRangePreset.All;
    public DateTime CustomSince { get; set; } = DateTime.Today.AddMonths(-1);
    public DateTime CustomUntil { get; set; } = DateTime.Today;
    public HashSet<string> EnabledMessageTypes { get; set; } =
        MessageTypeFilterInfo.AllIds().ToHashSet(StringComparer.OrdinalIgnoreCase);
    public bool IncrementalExport { get; set; }
    public bool MapGroupNicknames { get; set; } = true;
    public bool EnableSpeechToText { get; set; }
    public HashSet<string> FavoriteIds { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    public (DateTime? since, DateTime? until) ResolvedDateRange()
    {
        var now = DateTime.Now;
        return DateRangePreset switch
        {
            DateRangePreset.Last7Days => (now.AddDays(-7), now),
            DateRangePreset.Last30Days => (now.AddDays(-30), now),
            DateRangePreset.Last90Days => (now.AddDays(-90), now),
            DateRangePreset.Last365Days => (now.AddDays(-365), now),
            DateRangePreset.Custom => (CustomSince, CustomUntil),
            _ => (null, null)
        };
    }

    private static string SettingsPath =>
        System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "WeChatExporter",
            "settings.json");

    private static string DefaultExportPath() =>
        System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Downloads",
            "微信聊天记录导出");

    public void Save()
    {
        var dir = System.IO.Path.GetDirectoryName(SettingsPath)!;
        System.IO.Directory.CreateDirectory(dir);
        var json = JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });
        System.IO.File.WriteAllText(SettingsPath, json);
    }

    private static AppSettings Load()
    {
        try
        {
            if (System.IO.File.Exists(SettingsPath))
            {
                var json = System.IO.File.ReadAllText(SettingsPath);
                var loaded = JsonSerializer.Deserialize<AppSettings>(json);
                if (loaded is not null)
                {
                    if (string.IsNullOrWhiteSpace(loaded.ExportPath))
                        loaded.ExportPath = DefaultExportPath();
                    if (loaded.CustomSince == default)
                        loaded.CustomSince = DateTime.Today.AddMonths(-1);
                    if (loaded.CustomUntil == default)
                        loaded.CustomUntil = DateTime.Today;
                    loaded.EnabledMessageTypes = NormalizeTypeSet(loaded.EnabledMessageTypes);
                    loaded.FavoriteIds = new HashSet<string>(
                        loaded.FavoriteIds.Where(id => !string.IsNullOrWhiteSpace(id)),
                        StringComparer.OrdinalIgnoreCase);
                    return loaded;
                }
            }
        }
        catch
        {
            // fall through to defaults
        }
        return new AppSettings();
    }

    private static HashSet<string> NormalizeTypeSet(HashSet<string>? raw)
    {
        var all = MessageTypeFilterInfo.AllIds().ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (raw is null || raw.Count == 0)
            return all;

        var normalized = raw
            .Where(id => all.Contains(id))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        return normalized.Count == 0 ? all : normalized;
    }
}
