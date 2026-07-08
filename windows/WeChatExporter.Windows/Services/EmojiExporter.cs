using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace WeChatExporter.Services;

/// <summary>
/// 从 wx-cli 导出的 JSON 中解析表情 XML，下载 GIF/PNG 到 media/emojis/
/// </summary>
internal static class EmojiExporter
{
    private static readonly Regex EmojiTagRegex = new(@"<emoji\b[^>]*(?:/>|>[^<]*</emoji>)", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex AttrRegex = new(@"(\w+)=""([^""]*)""", RegexOptions.Compiled);
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };

    static EmojiExporter()
    {
        Http.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0");
    }

    public static async Task<int> ExportEmojisAsync(string outputDir, Action<string> log, CancellationToken cancellationToken = default)
    {
        var jsonPath = Path.Combine(outputDir, "chat.json");
        if (!File.Exists(jsonPath)) return 0;

        var jsonText = await File.ReadAllTextAsync(jsonPath, cancellationToken);
        using var doc = JsonDocument.Parse(jsonText);
        if (!TryGetMutableItems(doc.RootElement, out var itemsPath, out var items) || items.Count == 0)
            return 0;

        var emojiDir = Path.Combine(outputDir, "media", "emojis");
        Directory.CreateDirectory(emojiDir);

        var downloaded = 0;
        var seenNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        for (var i = 0; i < items.Count; i++)
        {
            var item = CloneJson(items[i]);
            var xmlSources = CollectEmojiXml(item);
            if (xmlSources.Count == 0) continue;

            foreach (var xml in xmlSources)
            {
                var attrs = ParseAttributes(xml);
                if (!TryPickUrl(attrs, out var urlString)) continue;

                var filename = UniqueFilename(MakeFilename(attrs, i), seenNames);
                var dest = Path.Combine(emojiDir, filename);
                var mediaPath = $"media/emojis/{filename}";

                if (File.Exists(dest) || await DownloadAsync(urlString, dest, cancellationToken))
                {
                    item = AppendMediaFile(item, mediaPath);
                    downloaded++;
                    if (!File.Exists(dest))
                        log($"已下载表情：{filename}");
                }
                else
                {
                    log($"表情下载失败：{filename}");
                }
            }

            items[i] = item;
        }

        if (downloaded == 0) return 0;

        await WriteItemsAsync(jsonPath, doc.RootElement, itemsPath, items, cancellationToken);
        log($"共导出 {downloaded} 个表情文件 → media/emojis/");
        return downloaded;
    }

    private static bool TryGetMutableItems(JsonElement root, out string path, out List<JsonElement> items)
    {
        path = "";
        items = [];
        if (root.ValueKind == JsonValueKind.Array)
        {
            path = "$";
            items = root.EnumerateArray().Select(CloneJson).ToList();
            return items.Count > 0;
        }

        if (root.ValueKind != JsonValueKind.Object) return false;
        foreach (var key in new[] { "items", "messages", "results" })
        {
            if (root.TryGetProperty(key, out var arr) && arr.ValueKind == JsonValueKind.Array)
            {
                path = key;
                items = arr.EnumerateArray().Select(CloneJson).ToList();
                return items.Count > 0;
            }
        }
        return false;
    }

    private static async Task WriteItemsAsync(
        string jsonPath,
        JsonElement root,
        string itemsPath,
        List<JsonElement> items,
        CancellationToken cancellationToken)
    {
        using var stream = new MemoryStream();
        await using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true }))
        {
            WriteRootWithItems(writer, root, itemsPath, items);
        }
        await File.WriteAllBytesAsync(jsonPath, stream.ToArray(), cancellationToken);
    }

    private static void WriteRootWithItems(Utf8JsonWriter writer, JsonElement root, string itemsPath, List<JsonElement> items)
    {
        if (itemsPath == "$")
        {
            writer.WriteStartArray();
            foreach (var item in items) item.WriteTo(writer);
            writer.WriteEndArray();
            return;
        }

        writer.WriteStartObject();
        foreach (var prop in root.EnumerateObject())
        {
            if (prop.NameEquals(itemsPath))
            {
                writer.WritePropertyName(prop.Name);
                writer.WriteStartArray();
                foreach (var item in items) item.WriteTo(writer);
                writer.WriteEndArray();
            }
            else
            {
                prop.WriteTo(writer);
            }
        }
        writer.WriteEndObject();
    }

    private static List<string> CollectEmojiXml(JsonElement element)
    {
        var texts = new List<string>();
        CollectStrings(element, texts);
        var xmls = new List<string>();
        foreach (var text in texts)
        {
            foreach (Match match in EmojiTagRegex.Matches(text))
            {
                var value = match.Value;
                if (!xmls.Contains(value)) xmls.Add(value);
            }
        }
        return xmls;
    }

    private static void CollectStrings(JsonElement element, List<string> outTexts)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.String:
                var s = element.GetString() ?? "";
                if (s.Contains("<emoji", StringComparison.OrdinalIgnoreCase)) outTexts.Add(s);
                break;
            case JsonValueKind.Object:
                foreach (var prop in element.EnumerateObject()) CollectStrings(prop.Value, outTexts);
                break;
            case JsonValueKind.Array:
                foreach (var item in element.EnumerateArray()) CollectStrings(item, outTexts);
                break;
        }
    }

    private static Dictionary<string, string> ParseAttributes(string xml)
    {
        var attrs = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (Match match in AttrRegex.Matches(xml))
        {
            attrs[match.Groups[1].Value.ToLowerInvariant()] = match.Groups[2].Value;
        }
        return attrs;
    }

    private static bool TryPickUrl(Dictionary<string, string> attrs, out string url)
    {
        foreach (var key in new[] { "cdnurl", "tpurl", "encrypturl", "externurl", "thumburl", "cdnthumburl" })
        {
            if (attrs.TryGetValue(key, out url!) && !string.IsNullOrWhiteSpace(url) && url != "null")
            {
                url = UnescapeXml(url);
                return true;
            }
        }
        url = "";
        return false;
    }

    private static string MakeFilename(Dictionary<string, string> attrs, int index)
    {
        var md5 = attrs.GetValueOrDefault("md5")
            ?? attrs.GetValueOrDefault("androidmd5")
            ?? attrs.GetValueOrDefault("externmd5")
            ?? $"emoji_{index}";
        var ext = GuessExtension(attrs);
        return SanitizeFilename($"{md5}.{ext}");
    }

    private static string GuessExtension(Dictionary<string, string> attrs)
    {
        if (attrs.GetValueOrDefault("type") == "2") return "gif";
        foreach (var key in new[] { "cdnurl", "tpurl", "externurl", "thumburl" })
        {
            if (!attrs.TryGetValue(key, out var url)) continue;
            url = url.ToLowerInvariant();
            if (url.Contains(".gif")) return "gif";
            if (url.Contains(".png")) return "png";
            if (url.Contains(".jpg") || url.Contains(".jpeg")) return "jpg";
            if (url.Contains(".webp")) return "webp";
        }
        return "gif";
    }

    private static string UniqueFilename(string baseName, HashSet<string> seen)
    {
        if (seen.Add(baseName)) return baseName;
        var stem = Path.GetFileNameWithoutExtension(baseName);
        var ext = Path.GetExtension(baseName).TrimStart('.');
        for (var n = 2; ; n++)
        {
            var candidate = string.IsNullOrEmpty(ext) ? $"{stem}_{n}" : $"{stem}_{n}.{ext}";
            if (seen.Add(candidate)) return candidate;
        }
    }

    private static string SanitizeFilename(string name) =>
        string.Concat(name.Split(Path.GetInvalidFileNameChars()));

    private static string UnescapeXml(string s) =>
        s.Replace("&amp;", "&").Replace("&lt;", "<").Replace("&gt;", ">")
            .Replace("&quot;", "\"").Replace("&#39;", "'");

    private static JsonElement AppendMediaFile(JsonElement item, string path)
    {
        var obj = item.ValueKind == JsonValueKind.Object
            ? item.EnumerateObject().ToDictionary(p => p.Name, p => CloneJson(p.Value))
            : new Dictionary<string, JsonElement>();

        if (!obj.TryGetValue("media_files", out var filesEl) || filesEl.ValueKind != JsonValueKind.Array)
        {
            obj["media_files"] = JsonSerializer.SerializeToElement(new[] { path });
        }
        else
        {
            var files = filesEl.EnumerateArray().Select(e => e.GetString() ?? "").Where(s => s.Length > 0).ToList();
            if (!files.Contains(path)) files.Add(path);
            obj["media_files"] = JsonSerializer.SerializeToElement(files);
        }

        return JsonSerializer.SerializeToElement(obj);
    }

    private static JsonElement CloneJson(JsonElement element) =>
        JsonSerializer.Deserialize<JsonElement>(element.GetRawText());

    private static async Task<bool> DownloadAsync(string url, string dest, CancellationToken cancellationToken)
    {
        try
        {
            using var response = await Http.GetAsync(url, cancellationToken);
            if (!response.IsSuccessStatusCode) return false;
            var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
            if (bytes.Length == 0) return false;
            await File.WriteAllBytesAsync(dest, bytes, cancellationToken);
            return true;
        }
        catch
        {
            return false;
        }
    }
}
