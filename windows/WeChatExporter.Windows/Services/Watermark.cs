using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace WeChatExporter.Services;

/// <summary>
/// 导出水印（与 macOS Services/Watermark.swift 对称实现，双端行为一致）。
/// 水印文字默认「林琝淏科技集团有限公司」，可在设置中修改；开关默认开启（关闭即无水印版本）。
/// 持久化：settings.json（%APPDATA%/WeChatExporter/settings.json，与 DiagnosticUploader 同目录，保留其他字段）。
/// </summary>
public static class Watermark
{
    public const string DefaultText = "林琝淏科技集团有限公司";

    private const string SettingsDirectoryName = "WeChatExporter";
    private const string SettingsFileName = "settings.json";
    private const string WatermarkEnabledKey = "watermark_enabled";
    private const string WatermarkTextKey = "watermark_text";

    private static string SettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        SettingsDirectoryName,
        SettingsFileName);

    /// <summary>是否启用导出水印（默认 true；未显式设置视为开启）。</summary>
    public static bool Enabled
    {
        get
        {
            try
            {
                if (!File.Exists(SettingsPath)) return true;
                using var doc = JsonDocument.Parse(File.ReadAllText(SettingsPath));
                if (doc.RootElement is { } root && root.TryGetProperty(WatermarkEnabledKey, out var el) && el.ValueKind == System.Text.Json.JsonValueKind.False)
                    return false;
                return true;
            }
            catch { return true; }
        }
        set { SetSettingsField(WatermarkEnabledKey, value ? "true" : "false"); }
    }

    /// <summary>水印文字（默认「林琝淏科技集团有限公司」）。</summary>
    public static string Text
    {
        get
        {
            try
            {
                if (!File.Exists(SettingsPath)) return DefaultText;
                using var doc = JsonDocument.Parse(File.ReadAllText(SettingsPath));
                if (doc.RootElement is { } root && root.TryGetProperty(WatermarkTextKey, out var el) && el.ValueKind == System.Text.Json.JsonValueKind.String)
                {
                    var s = el.GetString();
                    if (!string.IsNullOrWhiteSpace(s)) return s!;
                }
                return DefaultText;
            }
            catch { return DefaultText; }
        }
        set { SetSettingsField(WatermarkTextKey, value); }
    }

    /// <summary>当前生效水印（开关开且文字非空）。</summary>
    public static (bool Active, string Text) Current() =>
        (Enabled && !string.IsNullOrWhiteSpace(Text) ? true : false, Text.Trim());

    private static void SetSettingsField(string key, string jsonValue)
    {
        try
        {
            var dir = Path.GetDirectoryName(SettingsPath)!;
            Directory.CreateDirectory(dir);
            JsonObject obj;
            if (File.Exists(SettingsPath))
            {
                try { obj = JsonNode.Parse(File.ReadAllText(SettingsPath)) as JsonObject ?? new JsonObject(); }
                catch { obj = new JsonObject(); }
            }
            else
            {
                obj = new JsonObject();
            }
            obj[key] = jsonValue.StartsWith("\"") || jsonValue is "true" or "false" or "null"
                ? JsonValue.Parse(jsonValue)
                : jsonValue;
            File.WriteAllText(SettingsPath, obj.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
        }
        catch { /* 设置写入失败不影响导出 */ }
    }

    /// <summary>HTML 视觉水印层：固定全屏平铺斜纹文字（CSS SVG data URI，零依赖，离线可渲染）。</summary>
    /// <param name="lightBackground">产物背景为浅色（打印版 HTML / 文档）时用深色水印。</param>
    public static string HtmlOverlay(bool lightBackground = false)
    {
        var (active, text) = Current();
        if (!active) return string.Empty;
        var fill = lightBackground ? "rgba(0,0,0,0.10)" : "rgba(255,255,255,0.14)";
        var uri = SvgDataUri(text, fill);
        return "<div class=\"wm-overlay\" aria-hidden=\"true\"></div>"
             + "<style>.wm-overlay{position:fixed;inset:0;z-index:2147483000;pointer-events:none;background-repeat:repeat;background-image:url(\"data:image/svg+xml;charset=utf-8," + uri + "\");}</style>";
    }

    /// <summary>HTML 页脚版权行（追加在文档 footer / 末尾）。</summary>
    public static string HtmlFooter()
    {
        var (active, text) = Current();
        if (!active) return string.Empty;
        return "<p class=\"wm-footer\" style=\"text-align:center;opacity:.7;font-size:12px;margin:16px 0 0\">© " + HtmlEscape(text) + "</p>";
    }

    /// <summary>纯文本版权行（EPUB 等文档产物）。</summary>
    public static string PlainLine()
    {
        var (active, text) = Current();
        if (!active) return string.Empty;
        return "© " + text;
    }

    /// <summary>幂等后处理：递归扫描目录内全部 *.html，缺水印层的注入 overlay + 页脚版权行（已含的跳过）。</summary>
    public static int ApplyToDirectory(string dir, Action<string>? log = null)
    {
        var (active, _) = Current();
        if (!active || !Directory.Exists(dir)) return 0;
        var count = 0;
        foreach (var file in Directory.EnumerateFiles(dir, "*.html", SearchOption.AllDirectories))
        {
            var raw = File.ReadAllText(file);
            if (raw.Contains("wm-overlay")) continue;
            var patched = raw;
            var bodyIdx = patched.IndexOf("<body", StringComparison.Ordinal);
            if (bodyIdx >= 0)
                bodyIdx = patched.IndexOf('>', bodyIdx) + 1;
            else
                bodyIdx = 0;
            var withOverlay = patched[..bodyIdx] + HtmlOverlay() + patched[bodyIdx..];
            var closeIdx = withOverlay.LastIndexOf("</body>", StringComparison.Ordinal);
            patched = closeIdx >= 0
                ? withOverlay[..closeIdx] + HtmlFooter() + withOverlay[closeIdx..]
                : withOverlay;
            try
            {
                File.WriteAllText(file, patched);
                count++;
            }
            catch { /* 单文件失败不阻塞 */ }
        }
        if (count > 0) log?.Invoke($"已为 {count} 份 HTML 注入水印");
        return count;
    }

    /// <summary>水印 SVG 的 data URI（UTF-8 字节逐字节 percent-encode，ASCII 安全字符原样保留）。</summary>
    private static string SvgDataUri(string text, string fill)
    {
        var t = HtmlEscape(text);
        var svg = "<svg xmlns='http://www.w3.org/2000/svg' width='300' height='180'>"
            + "<text x='150' y='90' font-size='20' font-family='-apple-system, PingFang SC, Microsoft YaHei, sans-serif'"
            + " fill='" + fill + "' text-anchor='middle' dominant-baseline='middle'"
            + " transform='rotate(-18 150 90)'>" + t + "</text></svg>";
        var data = Encoding.UTF8.GetBytes(svg);
        const string safeChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~'():";
        var safe = safeChars.ToHashSet();
        var out2 = new StringBuilder(data.Length * 3);
        foreach (var b in data)
        {
            if (b < 128 && safe.Contains((char)b)) out2.Append((char)b);
            else out2.Append('%').Append(((ushort)b).ToString("X2"));
        }
        return out2.ToString();
    }

    /// <summary>HTML 转义。</summary>
    public static string HtmlEscape(string s) =>
        s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");
}
