using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace WeChatExporter.Services;

/// <summary>
/// 将临时导出结果整理为「文字 + 图片/音频/视频分目录」的会话文件夹。
/// </summary>
internal static class FolderBundleExporter
{
    public sealed record Result(
        string FolderPath,
        int MessageCount,
        int ImageCount,
        int AudioCount,
        int VideoCount,
        int EmojiCount);

    private static readonly HashSet<string> ImageExts = new(StringComparer.OrdinalIgnoreCase)
        { "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "tif", "tiff" };
    private static readonly HashSet<string> AudioExts = new(StringComparer.OrdinalIgnoreCase)
        { "mp3", "m4a", "aac", "wav", "ogg", "silk", "amr", "mpga" };
    private static readonly HashSet<string> VideoExts = new(StringComparer.OrdinalIgnoreCase)
        { "mp4", "mov", "m4v", "avi", "mkv", "webm" };

    public static Result Write(string sourceDir, string contactName, string destinationDir, Action<string> log)
    {
        var jsonPath = Path.Combine(sourceDir, "chat.json");
        var txtPath = Path.Combine(sourceDir, "chat.txt");
        if (!File.Exists(jsonPath) && !File.Exists(txtPath))
            throw new InvalidOperationException("未找到聊天记录文件，无法生成分类文件夹");

        var messageCount = CountMessages(sourceDir);
        if (messageCount <= 0 && !File.Exists(txtPath))
            throw new InvalidOperationException("聊天记录为空，无法生成分类文件夹");

        var safeName = SanitizeFilename(string.IsNullOrWhiteSpace(contactName) ? "聊天记录" : contactName);
        var stamp = FileStamp();
        var folder = Path.Combine(destinationDir, $"{safeName}_{stamp}");
        var imagesDir = Path.Combine(folder, "图片");
        var audioDir = Path.Combine(folder, "音频");
        var videoDir = Path.Combine(folder, "视频");
        var emojiDir = Path.Combine(folder, "表情");
        Directory.CreateDirectory(imagesDir);
        Directory.CreateDirectory(audioDir);
        Directory.CreateDirectory(videoDir);
        Directory.CreateDirectory(emojiDir);

        var textDest = Path.Combine(folder, "文字记录.txt");
        if (File.Exists(txtPath))
            File.Copy(txtPath, textDest, true);
        else
            File.WriteAllText(textDest, BuildTextFromJson(jsonPath, contactName), Encoding.UTF8);

        var csvPath = Path.Combine(sourceDir, "chat.csv");
        if (File.Exists(csvPath))
            File.Copy(csvPath, Path.Combine(folder, "聊天记录.csv"), true);

        var imageCount = 0;
        var audioCount = 0;
        var videoCount = 0;
        var emojiCount = 0;
        var used = new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase)
        {
            ["图片"] = new(StringComparer.OrdinalIgnoreCase),
            ["音频"] = new(StringComparer.OrdinalIgnoreCase),
            ["视频"] = new(StringComparer.OrdinalIgnoreCase),
            ["表情"] = new(StringComparer.OrdinalIgnoreCase),
        };

        var mediaRoot = Path.Combine(sourceDir, "media");
        if (Directory.Exists(mediaRoot))
        {
            foreach (var filePath in Directory.EnumerateFiles(mediaRoot, "*", SearchOption.AllDirectories))
            {
                var rel = Path.GetRelativePath(mediaRoot, filePath).Replace('\\', '/');
                var isEmoji = rel.Contains("/emojis/", StringComparison.OrdinalIgnoreCase)
                              || rel.StartsWith("emojis/", StringComparison.OrdinalIgnoreCase);

                var source = filePath;
                var ext = Path.GetExtension(filePath).TrimStart('.').ToLowerInvariant();
                if (ext == "wxgf")
                {
                    var transcoded = WXGFTranscoder.TranscodeIfNeeded(filePath, log);
                    if (transcoded is not null)
                    {
                        source = transcoded;
                        ext = Path.GetExtension(transcoded).TrimStart('.').ToLowerInvariant();
                    }
                }

                if (isEmoji)
                {
                    var dest = UniqueDest(emojiDir, Path.GetFileName(source), used["表情"]);
                    if (CopyFile(source, dest)) emojiCount++;
                    continue;
                }

                if (ImageExts.Contains(ext) || ext == "wxgf")
                {
                    var dest = UniqueDest(imagesDir, Path.GetFileName(source), used["图片"]);
                    if (CopyFile(source, dest)) imageCount++;
                    continue;
                }

                if (AudioExts.Contains(ext))
                {
                    if (ConvertAudioToMp3(source, audioDir, used["音频"], log) is not null)
                    {
                        audioCount++;
                    }
                    else
                    {
                        var dest = UniqueDest(audioDir, Path.GetFileName(source), used["音频"]);
                        if (CopyFile(source, dest))
                        {
                            audioCount++;
                            if (ext == "silk")
                                log($"语音保留为 SILK：{Path.GetFileName(dest)}（未检测到可转码的 ffmpeg）");
                        }
                    }
                    continue;
                }

                if (VideoExts.Contains(ext))
                {
                    if (EnsureMp4(source, videoDir, used["视频"], log) is not null)
                    {
                        videoCount++;
                    }
                    else
                    {
                        var dest = UniqueDest(videoDir, Path.GetFileName(source), used["视频"]);
                        if (CopyFile(source, dest)) videoCount++;
                    }
                }
            }
        }

        var readme = $"""
            微信聊天记录分类导出
            ==================
            联系人：{contactName}
            导出时间：{stamp}
            消息条数：{Math.Max(messageCount, 0)}

            目录说明：
            - 文字记录.txt ：全部文字消息
            - 聊天记录.csv ：表格格式（若已生成）
            - 图片/         ：聊天图片
            - 音频/         ：语音（优先 mp3）
            - 视频/         ：视频（优先 mp4）
            - 表情/         ：表情/贴纸

            统计：图片 {imageCount} · 音频 {audioCount} · 视频 {videoCount} · 表情 {emojiCount}
            """;
        File.WriteAllText(Path.Combine(folder, "导出说明.txt"), readme, Encoding.UTF8);
        log($"分类文件夹已生成：{Path.GetFileName(folder)}（图{imageCount}/音{audioCount}/视{videoCount}/表情{emojiCount}）");
        return new Result(folder, Math.Max(messageCount, 0), imageCount, audioCount, videoCount, emojiCount);
    }

    private static int CountMessages(string sourceDir)
    {
        var jsonPath = Path.Combine(sourceDir, "chat.json");
        if (File.Exists(jsonPath))
        {
            try
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(jsonPath));
                var root = doc.RootElement;
                if (root.ValueKind == JsonValueKind.Array) return root.GetArrayLength();
                if (root.ValueKind == JsonValueKind.Object)
                {
                    foreach (var key in new[] { "items", "messages", "results" })
                    {
                        if (root.TryGetProperty(key, out var arr) && arr.ValueKind == JsonValueKind.Array)
                            return arr.GetArrayLength();
                    }
                    if (root.TryGetProperty("conversation", out var conversation)
                        && conversation.ValueKind == JsonValueKind.Object
                        && conversation.TryGetProperty("message_count", out var count)
                        && count.TryGetInt32(out var n))
                    {
                        return n;
                    }
                }
            }
            catch { /* fall through */ }
        }

        var txtPath = Path.Combine(sourceDir, "chat.txt");
        if (File.Exists(txtPath))
            return File.ReadAllLines(txtPath).Count(l => l.StartsWith('['));
        return 0;
    }

    private static string BuildTextFromJson(string jsonPath, string contactName)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(jsonPath));
        var root = doc.RootElement;
        var rows = new List<JsonElement>();
        if (root.ValueKind == JsonValueKind.Array)
            rows.AddRange(root.EnumerateArray());
        else if (root.ValueKind == JsonValueKind.Object)
        {
            foreach (var key in new[] { "items", "messages", "results" })
            {
                if (root.TryGetProperty(key, out var arr) && arr.ValueKind == JsonValueKind.Array)
                {
                    rows.AddRange(arr.EnumerateArray());
                    break;
                }
            }
        }

        var sb = new StringBuilder();
        sb.AppendLine($"微信聊天记录: {contactName}");
        sb.AppendLine($"总消息数: {rows.Count}");
        sb.AppendLine(new string('=', 60));
        sb.AppendLine();
        foreach (var row in rows)
        {
            var source = row.TryGetProperty("message", out var nested) && nested.ValueKind == JsonValueKind.Object
                ? nested : row;
            var sender = GetString(row, "sender_display_name", "sender")
                         ?? GetString(source, "sender_display_name", "sender")
                         ?? "未知";
            var content = GetString(row, "snippet", "content", "text")
                          ?? GetString(source, "content", "text")
                          ?? "";
            var time = GetString(row, "time") ?? "";
            sb.AppendLine($"[{time}] {sender}: {content}");
        }
        return sb.ToString();
    }

    private static string? GetString(JsonElement el, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (el.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String)
            {
                var s = v.GetString();
                if (!string.IsNullOrEmpty(s)) return s;
            }
        }
        return null;
    }

    private static bool CopyFile(string source, string dest)
    {
        try
        {
            File.Copy(source, dest, true);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static string UniqueDest(string dir, string preferredName, HashSet<string> used)
    {
        var name = SanitizeFilename(preferredName);
        if (string.IsNullOrWhiteSpace(name)) name = "file";
        var candidate = name;
        var index = 1;
        while (used.Contains(candidate))
        {
            var baseName = Path.GetFileNameWithoutExtension(name);
            var ext = Path.GetExtension(name);
            candidate = $"{baseName}_{index}{ext}";
            index++;
        }
        used.Add(candidate);
        return Path.Combine(dir, candidate);
    }

    private static string? ConvertAudioToMp3(string source, string dir, HashSet<string> used, Action<string> log)
    {
        var ext = Path.GetExtension(source).TrimStart('.').ToLowerInvariant();
        if (ext == "mp3")
        {
            var dest = UniqueDest(dir, Path.GetFileName(source), used);
            return CopyFile(source, dest) ? dest : null;
        }

        var ffmpeg = LocateFfmpeg();
        if (ffmpeg is null) return null;
        var destMp3 = UniqueDest(dir, Path.GetFileNameWithoutExtension(source) + ".mp3", used);
        if (RunFfmpeg(ffmpeg, ["-y", "-hide_banner", "-loglevel", "error", "-i", source, destMp3]))
        {
            log($"已转码音频为 MP3：{Path.GetFileName(destMp3)}");
            return destMp3;
        }
        return null;
    }

    private static string? EnsureMp4(string source, string dir, HashSet<string> used, Action<string> log)
    {
        var ext = Path.GetExtension(source).TrimStart('.').ToLowerInvariant();
        if (ext == "mp4")
        {
            var dest = UniqueDest(dir, Path.GetFileName(source), used);
            return CopyFile(source, dest) ? dest : null;
        }

        var ffmpeg = LocateFfmpeg();
        if (ffmpeg is null) return null;
        var destMp4 = UniqueDest(dir, Path.GetFileNameWithoutExtension(source) + ".mp4", used);
        if (RunFfmpeg(ffmpeg, ["-y", "-hide_banner", "-loglevel", "error", "-i", source, "-c", "copy", destMp4])
            || RunFfmpeg(ffmpeg, ["-y", "-hide_banner", "-loglevel", "error", "-i", source, destMp4]))
        {
            log($"已转换为 MP4：{Path.GetFileName(destMp4)}");
            return destMp4;
        }
        return null;
    }

    private static bool RunFfmpeg(string ffmpeg, IReadOnlyList<string> args)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = ffmpeg,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            foreach (var a in args) psi.ArgumentList.Add(a);
            using var proc = Process.Start(psi);
            if (proc is null) return false;
            proc.WaitForExit();
            return proc.ExitCode == 0;
        }
        catch
        {
            return false;
        }
    }

    private static string? LocateFfmpeg()
    {
        var pathEnv = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in pathEnv.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            foreach (var name in new[] { "ffmpeg.exe", "ffmpeg" })
            {
                var candidate = Path.Combine(dir.Trim(), name);
                if (File.Exists(candidate)) return candidate;
            }
        }
        foreach (var candidate in new[]
                 {
                     @"C:\Program Files\ffmpeg\bin\ffmpeg.exe",
                     @"C:\ffmpeg\bin\ffmpeg.exe",
                     "/opt/homebrew/bin/ffmpeg",
                     "/usr/local/bin/ffmpeg",
                     "/usr/bin/ffmpeg",
                 })
        {
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    private static string FileStamp()
    {
        var tz = TimeZoneInfo.FindSystemTimeZoneById(
            OperatingSystem.IsWindows() ? "China Standard Time" : "Asia/Shanghai");
        return TimeZoneInfo.ConvertTime(DateTimeOffset.Now, tz).ToString("yyyyMMdd_HHmmss");
    }

    private static string SanitizeFilename(string name)
    {
        var cleaned = Regex.Replace(name, "[/\\\\:\\?\\*\"<>\\|]", "_");
        return string.IsNullOrWhiteSpace(cleaned) ? "聊天记录" : cleaned;
    }
}
