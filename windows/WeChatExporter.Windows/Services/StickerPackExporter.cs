using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace WeChatExporter.Services;

/// <summary>
/// 从 wx-cli 解密缓存中的 emoticon.db 导出全部收藏/商店表情包。
/// </summary>
internal static class StickerPackExporter
{
    internal sealed record StickerItem(string Path, string Md5, string Caption);
    internal sealed record StickerPack(string Id, string Name, List<StickerItem> Stickers);
    internal sealed record Manifest(List<StickerPack> Packs, int TotalCount);

    private sealed record LookupEntry(string CdnUrl, string EncryptUrl, string AesKey, string ProductId, string Caption);
    private sealed record LookupResult(Dictionary<string, LookupEntry> Lookup, Dictionary<string, string> PackNames);

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };

    static StickerPackExporter()
    {
        Http.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0");
    }

    public static async Task<int> ExportAllPacksAsync(string outputDir, Action<string> log, CancellationToken cancellationToken = default)
    {
        var dbPath = LocateEmoticonDb();
        if (dbPath is null)
        {
            log("未找到 emoticon.db，跳过全部表情包导出（请先点击「准备数据」）");
            return 0;
        }

        var result = LoadLookup(dbPath);
        if (result.Lookup.Count == 0)
        {
            log("emoticon.db 中未找到表情包记录");
            return 0;
        }

        var stickersRoot = Path.Combine(outputDir, "media", "stickers");
        Directory.CreateDirectory(stickersRoot);

        var packs = new Dictionary<string, (string Name, List<StickerItem> Items)>(StringComparer.OrdinalIgnoreCase);
        var downloaded = 0;

        foreach (var (md5, info) in result.Lookup.OrderBy(kv => kv.Key, StringComparer.Ordinal))
        {
            var packId = string.IsNullOrEmpty(info.ProductId) ? "favorites" : info.ProductId;
            var packName = result.PackNames.GetValueOrDefault(packId)
                ?? (packId == "favorites" ? "收藏表情" : packId);
            var packDir = Path.Combine(stickersRoot, SanitizeFilename(packId));
            Directory.CreateDirectory(packDir);

            var filename = await DownloadStickerAsync(md5, info, packDir, cancellationToken);
            if (filename is null) continue;

            downloaded++;
            var rel = $"media/stickers/{SanitizeFilename(packId)}/{filename}";
            if (!packs.TryGetValue(packId, out var bucket))
                bucket = (packName, []);
            bucket.Items.Add(new StickerItem(rel, md5, info.Caption));
            packs[packId] = bucket;
        }

        if (downloaded == 0)
        {
            log("表情包下载完成：0 个（可能 CDN 链接已过期）");
            return 0;
        }

        var manifest = new Manifest(
            packs.Select(kv => new StickerPack(kv.Key, kv.Value.Name, kv.Value.Items)).OrderBy(p => p.Name).ToList(),
            downloaded);

        var manifestPath = Path.Combine(outputDir, "stickers-manifest.json");
        await File.WriteAllTextAsync(manifestPath, JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true }), cancellationToken);
        log($"共导出 {downloaded} 个表情包（{manifest.Packs.Count} 个分组）→ media/stickers/");
        return downloaded;
    }

    private static string? LocateEmoticonDb()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var cacheRoots = new[]
        {
            Path.Combine(home, ".wx-cli", "cache"),
            Path.Combine(home, "Library", "Caches", "wx-cli"),
        };

        string? best = null;
        DateTime bestTime = DateTime.MinValue;
        foreach (var root in cacheRoots)
        {
            if (!Directory.Exists(root)) continue;
            foreach (var accountDir in Directory.EnumerateDirectories(root))
            {
                var db = Path.Combine(accountDir, "db_storage", "emoticon", "emoticon.db");
                if (!File.Exists(db)) continue;
                if (!QuickCheckOk(db)) continue;
                var time = File.GetLastWriteTimeUtc(db);
                if (time > bestTime)
                {
                    bestTime = time;
                    best = db;
                }
            }
        }
        return best;
    }

    private static bool QuickCheckOk(string dbPath)
    {
        try
        {
            using var conn = new SqliteConnection($"Data Source={dbPath};Mode=ReadOnly");
            conn.Open();
            using var cmd = conn.CreateCommand();
            cmd.CommandText = "PRAGMA quick_check";
            return string.Equals(cmd.ExecuteScalar()?.ToString(), "ok", StringComparison.Ordinal);
        }
        catch
        {
            return false;
        }
    }

    private static LookupResult LoadLookup(string dbPath)
    {
        var lookup = new Dictionary<string, LookupEntry>(StringComparer.OrdinalIgnoreCase);
        var pkgTemplates = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var packNames = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        using var conn = new SqliteConnection($"Data Source={dbPath};Mode=ReadOnly");
        conn.Open();

        if (TableExists(conn, "kStoreEmoticonPackageTable"))
        {
            using var cmd = conn.CreateCommand();
            cmd.CommandText = "SELECT product_id_, product_name_ FROM kStoreEmoticonPackageTable";
            using var reader = cmd.ExecuteReader();
            while (reader.Read())
            {
                var id = reader.GetString(0);
                var name = reader.IsDBNull(1) ? "" : reader.GetString(1);
                if (!string.IsNullOrEmpty(id) && !string.IsNullOrEmpty(name))
                    packNames[id] = name;
            }
        }

        if (TableExists(conn, "kNonStoreEmoticonTable"))
        {
            using var cmd = conn.CreateCommand();
            cmd.CommandText = "SELECT md5, aes_key, cdn_url, encrypt_url, product_id FROM kNonStoreEmoticonTable";
            using var reader = cmd.ExecuteReader();
            while (reader.Read())
            {
                var md5 = reader.IsDBNull(0) ? "" : reader.GetString(0);
                if (string.IsNullOrEmpty(md5)) continue;
                var entry = new LookupEntry(
                    reader.IsDBNull(2) ? "" : reader.GetString(2),
                    reader.IsDBNull(3) ? "" : reader.GetString(3),
                    reader.IsDBNull(1) ? "" : reader.GetString(1),
                    reader.IsDBNull(4) ? "" : reader.GetString(4),
                    "");
                lookup[md5] = entry;
                if (!string.IsNullOrEmpty(entry.ProductId) && !string.IsNullOrEmpty(entry.CdnUrl))
                    pkgTemplates[entry.ProductId] = entry.CdnUrl;
            }
        }

        if (TableExists(conn, "kStoreEmoticonFilesTable"))
        {
            using var cmd = conn.CreateCommand();
            cmd.CommandText = "SELECT package_id_, md5_ FROM kStoreEmoticonFilesTable";
            using var reader = cmd.ExecuteReader();
            while (reader.Read())
            {
                var pkgId = reader.IsDBNull(0) ? "" : reader.GetString(0);
                var md5 = reader.IsDBNull(1) ? "" : reader.GetString(1);
                if (string.IsNullOrEmpty(md5) || lookup.ContainsKey(md5)) continue;
                var cdnUrl = "";
                if (pkgTemplates.TryGetValue(pkgId, out var template) && template.Contains('&'))
                    cdnUrl = Regex.Replace(template, "m=[0-9a-fA-F]+", $"m={md5}");
                lookup[md5] = new LookupEntry(cdnUrl, "", "", pkgId, "");
            }
        }

        if (TableExists(conn, "kStoreEmoticonCaptionsTable"))
        {
            using var cmd = conn.CreateCommand();
            cmd.CommandText = "SELECT md5_, caption_ FROM kStoreEmoticonCaptionsTable WHERE language_='default'";
            using var reader = cmd.ExecuteReader();
            while (reader.Read())
            {
                var md5 = reader.IsDBNull(0) ? "" : reader.GetString(0);
                var caption = reader.IsDBNull(1) ? "" : reader.GetString(1);
                if (lookup.TryGetValue(md5, out var entry))
                    lookup[md5] = entry with { Caption = caption };
            }
        }

        return new LookupResult(lookup, packNames);
    }

    private static bool TableExists(SqliteConnection conn, string table)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=$name LIMIT 1";
        cmd.Parameters.AddWithValue("$name", table);
        return cmd.ExecuteScalar() is not null;
    }

    private static async Task<string?> DownloadStickerAsync(
        string md5, LookupEntry info, string dir, CancellationToken cancellationToken)
    {
        foreach (var ext in new[] { "gif", "png", "jpg", "webp" })
        {
            var existing = Path.Combine(dir, $"{md5}.{ext}");
            if (File.Exists(existing)) return Path.GetFileName(existing);
        }

        var data = await FetchUrlAsync(info.CdnUrl, cancellationToken);
        if (data is null && !string.IsNullOrEmpty(info.EncryptUrl) && !string.IsNullOrEmpty(info.AesKey))
        {
            var enc = await FetchUrlAsync(info.EncryptUrl, cancellationToken);
            if (enc is not null) data = DecryptEmoticon(enc, info.AesKey);
        }

        if (data is null || data.Length < 4) return null;

        var outExt = DetectExtension(data);
        var filename = $"{md5}.{outExt}";
        var outputPath = Path.Combine(dir, filename);
        await File.WriteAllBytesAsync(outputPath, data, cancellationToken);
        if (outExt == "wxgf" && WXGFTranscoder.TranscodeIfNeeded(outputPath) is { } transcodedPath)
            return Path.GetFileName(transcodedPath);
        return filename;
    }

    private static async Task<byte[]?> FetchUrlAsync(string urlString, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(urlString) || urlString == "null") return null;
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

    private static byte[]? DecryptEmoticon(byte[] data, string aesKeyHex)
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

    private static string DetectExtension(byte[] data)
    {
        if (data.Length >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) return "jpg";
        if (data.Length >= 4 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) return "png";
        if (data.Length >= 3 && data[0] == 'G' && data[1] == 'I' && data[2] == 'F') return "gif";
        if (data.Length >= 4 && data[0] == 'R' && data[1] == 'I' && data[2] == 'F' && data[3] == 'F') return "webp";
        if (data.Length >= 4 && data[0] == 'W' && data[1] == 'X' && data[2] == 'G' && data[3] == 'F') return "wxgf";
        return "gif";
    }

    private static string SanitizeFilename(string name)
    {
        var cleaned = string.Concat(name.Split(Path.GetInvalidFileNameChars()));
        return string.IsNullOrWhiteSpace(cleaned) ? "stickers" : cleaned;
    }
}
