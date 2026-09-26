using System.IO;
using System.Text.RegularExpressions;

namespace WeChatExporter.Services;

/// <summary>导出产物通用工具（macOS AppViewModel.copyTextArtifacts / sanitizeContactDirName 对称）。</summary>
public static class ExportArtifacts
{
    private static readonly HashSet<string> TextExtensions =
        new(StringComparer.OrdinalIgnoreCase) { "txt", "json", "csv" };

    /// <summary>把 sourceDir 下的文字类文件（txt/json/csv）复制到 destDir（覆盖同名）。</summary>
    public static void CopyTextArtifacts(string sourceDir, string destDir)
    {
        if (!Directory.Exists(sourceDir)) return;
        try { Directory.CreateDirectory(destDir); } catch { /* ignore */ }
        foreach (var file in Directory.EnumerateFiles(sourceDir))
        {
            var ext = Path.GetExtension(file).TrimStart('.').ToLowerInvariant();
            if (!TextExtensions.Contains(ext)) continue;
            var dest = Path.Combine(destDir, Path.GetFileName(file));
            try
            {
                if (File.Exists(dest)) File.Delete(dest);
                File.Copy(file, dest);
            }
            catch { /* 单文件复制失败不阻塞 */ }
        }
    }

    /// <summary>会话目录名清洗：Windows 非法文件名字符 → 下划线（与 macOS sanitizeContactDirName 同口径）。</summary>
    public static string SanitizeDirName(string name)
    {
        var cleaned = Regex.Replace(name, @"[/\\:?*""<>|]", "_");
        return string.IsNullOrWhiteSpace(cleaned) ? "未命名会话" : cleaned;
    }
}
