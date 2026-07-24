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

    private static string SettingsPath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "WeChatExporter",
            "settings.json");

    private static string DefaultExportPath() =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Downloads",
            "微信聊天记录导出");

    public void Save()
    {
        var dir = Path.GetDirectoryName(SettingsPath)!;
        Directory.CreateDirectory(dir);
        var json = JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(SettingsPath, json);
    }

    private static AppSettings Load()
    {
        try
        {
            if (File.Exists(SettingsPath))
            {
                var json = File.ReadAllText(SettingsPath);
                var loaded = JsonSerializer.Deserialize<AppSettings>(json);
                if (loaded is not null)
                {
                    if (string.IsNullOrWhiteSpace(loaded.ExportPath))
                        loaded.ExportPath = DefaultExportPath();
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
}
