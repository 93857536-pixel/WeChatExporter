using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace WeChatExporter.Services;

/// <summary>
/// 从 wx-cli 导出的 JSON 中解析图片 XML，下载或解密后在 HTML 中内嵌显示。
/// </summary>
internal static class ImageExporter
{
    private static readonly Regex ImgTagRegex = new(@"<img\b[^>]*(?:/>|>[^<]*</img>)", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex AttrRegex = new(@"(\w+)=""([^""]*)""", RegexOptions.Compiled);
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };

    static ImageExporter()
    {
        Http.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0");
    }

    public static async Task<int> ExportImagesAsync(string outputDir, Action<string> log, CancellationToken cancellationToken = default)
    {
        var jsonPath = Path.Combine(outputDir, "chat.json");
        if (!File.Exists(jsonPath)) return 0;

        var jsonText = await File.ReadAllTextAsync(jsonPath, cancellationToken);
        using var doc = JsonDocument.Parse(jsonText);
        if (!TryGetMutableItems(doc.RootElement, out var itemsPath, out var items) || items.Count == 0)
            return 0;

        var imageDir = Path.Combine(outputDir, "media", "images");
        Directory.CreateDirectory(imageDir);

        var processed = 0;
        var seenNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        for (var i = 0; i < items.Count; i++)
        {
            var item = CloneJson(items[i]);
            var xmlSources = CollectImageXml(item);
            if (xmlSources.Count == 0) continue;

            foreach (var xml in xmlSources)
            {
                var attrs = ParseAttributes(xml);
                var filename = UniqueFilename(MakeFilename(attrs, i), seenNames);
                var dest = Path.Combine(imageDir, filename);
                var mediaPath = $"media/images/{filename}";

                if (File.Exists(dest))
                {
                    item = AppendMediaFile(item, mediaPath);
                    processed++;
                    continue;
                }

                if (await DownloadImageAsync(attrs, dest, cancellationToken))
                {
                    item = AppendMediaFile(item, mediaPath);
                    processed++;
                    log($"已下载图片：{filename}");
                }
                else
                {
                    log($"图片下载失败：{filename}");
                }
            }

            items[i] = item;
        }

        processed += await DatImageDecoder.DecodeDatFilesAsync(outputDir, log, cancellationToken);
        if (processed == 0) return 0;

        await WriteItemsAsync(jsonPath, doc.RootElement, itemsPath, items, cancellationToken);
        log($"共处理 {processed} 张聊天图片");
        return processed;
    }

    public static byte[]? NormalizeImageData(byte[] data) =>
        SniffImageMime(data) is not null ? data : DatImageDecoder.TryDecodeInline(data);

    public static string? SniffImageMime(byte[] data)
    {
        if (data.Length >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) return "image/jpeg";
        if (data.Length >= 4 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) return "image/png";
        if (data.Length >= 3 && data[0] == 'G' && data[1] == 'I' && data[2] == 'F') return "image/gif";
        if (data.Length > 12 && data[0] == 'R' && data[1] == 'I' && data[2] == 'F' && data[3] == 'F'
            && data[8] == 'W' && data[9] == 'E' && data[10] == 'B' && data[11] == 'P') return "image/webp";
        return null;
    }

    private static bool TryGetMutableItems(JsonElement root, out string path, out List<JsonElement> items) =>
        EmojiExporterHelpers.TryGetMutableItems(root, out path, out items);

    private static Task WriteItemsAsync(string jsonPath, JsonElement root, string itemsPath, List<JsonElement> items, CancellationToken cancellationToken) =>
        EmojiExporterHelpers.WriteItemsAsync(jsonPath, root, itemsPath, items, cancellationToken);

    private static JsonElement AppendMediaFile(JsonElement item, string path) =>
        EmojiExporterHelpers.AppendMediaFile(item, path);

    private static JsonElement CloneJson(JsonElement element) =>
        JsonSerializer.Deserialize<JsonElement>(element.GetRawText());

    private static List<string> CollectImageXml(JsonElement element)
    {
        var texts = new List<string>();
        CollectStrings(element, texts);
        var xmls = new List<string>();
        foreach (var text in texts.Where(t => t.Contains("<img", StringComparison.OrdinalIgnoreCase)))
        {
            foreach (Match match in ImgTagRegex.Matches(text))
            {
                if (!xmls.Contains(match.Value)) xmls.Add(match.Value);
            }
        }
        return xmls;
    }

    private static void CollectStrings(JsonElement element, List<string> outTexts)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.String:
                outTexts.Add(element.GetString() ?? "");
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
            attrs[match.Groups[1].Value.ToLowerInvariant()] = match.Groups[2].Value;
        return attrs;
    }

    private static bool TryPickUrl(Dictionary<string, string> attrs, out string url)
    {
        foreach (var key in new[] { "cdnbigimgurl", "cdnmidimgurl", "cdnthumburl", "cdnurl", "tpurl", "encrypturl", "attachurl" })
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
            ?? attrs.GetValueOrDefault("originsourcemd5")
            ?? $"image_{index}";
        return SanitizeFilename($"{md5}.{GuessExtension(attrs)}");
    }

    private static string GuessExtension(Dictionary<string, string> attrs)
    {
        foreach (var key in new[] { "cdnbigimgurl", "cdnmidimgurl", "cdnthumburl", "cdnurl" })
        {
            if (!attrs.TryGetValue(key, out var url)) continue;
            url = url.ToLowerInvariant();
            if (url.Contains(".png")) return "png";
            if (url.Contains(".webp")) return "webp";
            if (url.Contains(".gif")) return "gif";
            if (url.Contains(".jpg") || url.Contains(".jpeg")) return "jpg";
        }
        return "jpg";
    }

    private static async Task<bool> DownloadImageAsync(Dictionary<string, string> attrs, string dest, CancellationToken cancellationToken)
    {
        if (!TryPickUrl(attrs, out var urlString)) return false;
        byte[]? data = await FetchUrlAsync(urlString, cancellationToken);
        if (data is null && attrs.TryGetValue("encrypturl", out var encrypt) && !string.IsNullOrEmpty(encrypt)
            && attrs.TryGetValue("aeskey", out var aesKey) && !string.IsNullOrEmpty(aesKey))
        {
            var enc = await FetchUrlAsync(UnescapeXml(encrypt), cancellationToken);
            if (enc is not null) data = DecryptImage(enc, aesKey);
        }

        var normalized = data is null ? null : NormalizeImageData(data);
        if (normalized is null) return false;
        await File.WriteAllBytesAsync(dest, normalized, cancellationToken);
        return true;
    }

    private static async Task<byte[]?> FetchUrlAsync(string urlString, CancellationToken cancellationToken)
    {
        try
        {
            using var response = await Http.GetAsync(urlString, cancellationToken);
            if (!response.IsSuccessStatusCode) return null;
            var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
            return bytes.Length == 0 ? null : bytes;
        }
        catch
        {
            return null;
        }
    }

    private static byte[]? DecryptImage(byte[] data, string aesKeyHex)
    {
        try
        {
            var key = Convert.FromHexString(aesKeyHex);
            if (key.Length != 16) return null;
            using var aes = Aes.Create();
            aes.Mode = CipherMode.CBC;
            aes.Padding = PaddingMode.PKCS7;
            aes.Key = key;
            aes.IV = key;
            using var decryptor = aes.CreateDecryptor();
            return decryptor.TransformFinalBlock(data, 0, data.Length);
        }
        catch
        {
            return null;
        }
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
}

/// <summary>EmojiExporter 的 JSON 辅助方法复用。</summary>
internal static class EmojiExporterHelpers
{
    public static bool TryGetMutableItems(JsonElement root, out string path, out List<JsonElement> items)
    {
        path = "";
        items = [];
        if (root.ValueKind == JsonValueKind.Array)
        {
            path = "$";
            items = root.EnumerateArray().Select(e => JsonSerializer.Deserialize<JsonElement>(e.GetRawText())).ToList();
            return items.Count > 0;
        }

        if (root.ValueKind != JsonValueKind.Object) return false;
        foreach (var key in new[] { "items", "messages", "results" })
        {
            if (root.TryGetProperty(key, out var arr) && arr.ValueKind == JsonValueKind.Array)
            {
                path = key;
                items = arr.EnumerateArray().Select(e => JsonSerializer.Deserialize<JsonElement>(e.GetRawText())).ToList();
                return items.Count > 0;
            }
        }
        return false;
    }

    public static async Task WriteItemsAsync(
        string jsonPath, JsonElement root, string itemsPath, List<JsonElement> items, CancellationToken cancellationToken)
    {
        using var stream = new MemoryStream();
        await using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true }))
        {
            if (itemsPath == "$")
            {
                writer.WriteStartArray();
                foreach (var item in items) item.WriteTo(writer);
                writer.WriteEndArray();
            }
            else
            {
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
        }
        await File.WriteAllBytesAsync(jsonPath, stream.ToArray(), cancellationToken);
    }

    public static JsonElement AppendMediaFile(JsonElement item, string path)
    {
        var obj = item.ValueKind == JsonValueKind.Object
            ? item.EnumerateObject().ToDictionary(p => p.Name, p => JsonSerializer.Deserialize<JsonElement>(p.Value.GetRawText()))
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
}
