using System.Text.Json;

namespace WeChatExporter.Services;

/// <summary>Stores last successful create_time per talker for incremental exports.</summary>
public static class ExportCursorStore
{
    private static string StorePath =>
        System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "WeChatExporter",
            "export_cursors.json");

    public static long? LastExportedTime(string talker)
    {
        var key = Normalize(talker);
        if (string.IsNullOrEmpty(key)) return null;
        var dict = Load();
        return dict.TryGetValue(key, out var value) && value > 0 ? value : null;
    }

    public static void Remember(string talker, long lastCreateTime)
    {
        var key = Normalize(talker);
        if (string.IsNullOrEmpty(key) || lastCreateTime <= 0) return;
        var dict = Load();
        dict[key] = Math.Max(dict.TryGetValue(key, out var current) ? current : 0, lastCreateTime);
        Save(dict);
    }

    public static void Clear(string? talker = null)
    {
        if (string.IsNullOrWhiteSpace(talker))
        {
            try { if (System.IO.File.Exists(StorePath)) System.IO.File.Delete(StorePath); } catch { /* ignore */ }
            return;
        }

        var dict = Load();
        dict.Remove(Normalize(talker));
        Save(dict);
    }

    private static Dictionary<string, long> Load()
    {
        try
        {
            if (!System.IO.File.Exists(StorePath)) return new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            var json = System.IO.File.ReadAllText(StorePath);
            var raw = JsonSerializer.Deserialize<Dictionary<string, long>>(json)
                      ?? new Dictionary<string, long>();
            return new Dictionary<string, long>(raw, StringComparer.OrdinalIgnoreCase);
        }
        catch
        {
            return new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        }
    }

    private static void Save(Dictionary<string, long> dict)
    {
        try
        {
            var dir = System.IO.Path.GetDirectoryName(StorePath)!;
            System.IO.Directory.CreateDirectory(dir);
            var json = JsonSerializer.Serialize(dict, new JsonSerializerOptions { WriteIndented = true });
            System.IO.File.WriteAllText(StorePath, json);
        }
        catch
        {
            // Cursor persistence should never fail an export.
        }
    }

    private static string Normalize(string talker) => (talker ?? "").Trim();
}
