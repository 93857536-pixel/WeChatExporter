using System.Diagnostics;
using System.IO;

namespace WeChatExporter.Services;

/// <summary>将微信 WXGF 图片提取为 HEVC 首帧，并转成浏览器可显示的 JPEG。</summary>
internal static class WXGFTranscoder
{
    public static string? TranscodeIfNeeded(string filePath, Action<string>? log = null)
    {
        if (!File.Exists(filePath) || !string.Equals(Path.GetExtension(filePath), ".wxgf", StringComparison.OrdinalIgnoreCase))
            return null;

        var basePath = Path.Combine(Path.GetDirectoryName(filePath)!, Path.GetFileNameWithoutExtension(filePath));
        if (ExistingOutput(basePath) is { } existing)
            return existing;

        var data = File.ReadAllBytes(filePath);
        var hevc = ExtractHevcStream(data);
        if (hevc is null) return null;

        return TranscodeWithFfmpeg(hevc, basePath, log);
    }

    public static byte[]? ExtractHevcStream(byte[] data)
    {
        foreach (var signature in new[]
        {
            new byte[] { 0x00, 0x00, 0x00, 0x01, 0x40, 0x01 },
            new byte[] { 0x00, 0x00, 0x00, 0x01, 0x42, 0x01 },
        })
        {
            var index = IndexOf(data, signature);
            if (index >= 0) return data[index..];
        }
        return null;
    }

    private static string? ExistingOutput(string basePath)
    {
        foreach (var ext in new[] { "jpg", "jpeg", "png", "gif", "webp" })
        {
            var path = $"{basePath}.{ext}";
            if (File.Exists(path)) return path;
        }
        return null;
    }

    private static string? TranscodeWithFfmpeg(byte[] hevcData, string basePath, Action<string>? log)
    {
        var ffmpeg = LocateFfmpeg();
        if (ffmpeg is null) return null;

        var tempDir = Path.Combine(Path.GetTempPath(), $"wxgf-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);
        var inputPath = Path.Combine(tempDir, "frame.h265");
        var outputPath = $"{basePath}.jpg";

        try
        {
            File.WriteAllBytes(inputPath, hevcData);
            var psi = new ProcessStartInfo
            {
                FileName = ffmpeg,
                RedirectStandardError = true,
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add("-y");
            psi.ArgumentList.Add("-hide_banner");
            psi.ArgumentList.Add("-loglevel");
            psi.ArgumentList.Add("error");
            psi.ArgumentList.Add("-i");
            psi.ArgumentList.Add(inputPath);
            psi.ArgumentList.Add("-frames:v");
            psi.ArgumentList.Add("1");
            psi.ArgumentList.Add(outputPath);

            using var process = Process.Start(psi);
            if (process is null) return null;
            process.WaitForExit();

            if (process.ExitCode == 0 && File.Exists(outputPath))
            {
                log?.Invoke($"已转码 WXGF 图片：{Path.GetFileName(outputPath)}");
                return outputPath;
            }
            return null;
        }
        finally
        {
            try { if (Directory.Exists(tempDir)) Directory.Delete(tempDir, true); } catch { /* ignore */ }
        }
    }

    private static string? LocateFfmpeg()
    {
        var candidates = new List<string>();
        var pathEnv = Environment.GetEnvironmentVariable("PATH") ?? "";
        candidates.AddRange(pathEnv.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Select(dir => Path.Combine(dir, "ffmpeg.exe")));
        candidates.AddRange(pathEnv.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Select(dir => Path.Combine(dir, "ffmpeg")));
        candidates.AddRange(new[]
        {
            @"C:\Program Files\ffmpeg\bin\ffmpeg.exe",
            @"C:\ffmpeg\bin\ffmpeg.exe",
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        });
        return candidates.FirstOrDefault(File.Exists);
    }

    private static int IndexOf(byte[] haystack, byte[] needle)
    {
        for (var i = 0; i <= haystack.Length - needle.Length; i++)
        {
            var match = true;
            for (var j = 0; j < needle.Length; j++)
            {
                if (haystack[i + j] == needle[j]) continue;
                match = false;
                break;
            }
            if (match) return i;
        }
        return -1;
    }
}
