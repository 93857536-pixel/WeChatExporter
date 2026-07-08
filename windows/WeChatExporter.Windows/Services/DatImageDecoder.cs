using System.Diagnostics;
using System.IO;

namespace WeChatExporter.Services;

/// <summary>解密微信 .dat 图片，优先调用 wx-cli，失败时尝试 XOR 探测。</summary>
internal static class DatImageDecoder
{
    public static async Task<int> DecodeDatFilesAsync(string outputDir, Action<string> log, CancellationToken cancellationToken = default)
    {
        var mediaRoot = Path.Combine(outputDir, "media");
        if (!Directory.Exists(mediaRoot)) return 0;

        var datFiles = Directory.EnumerateFiles(mediaRoot, "*.dat", SearchOption.AllDirectories).ToList();
        if (datFiles.Count == 0) return 0;

        var decoded = 0;
        var accountDir = LocateWeChatAccountDir();
        var wxCli = WxCliService.LocateExecutable();

        foreach (var dat in datFiles)
        {
            var baseName = Path.GetFileNameWithoutExtension(dat);
            var outDir = Path.GetDirectoryName(dat)!;
            if (ExistingDecodedImage(baseName, outDir) is not null)
            {
                decoded++;
                continue;
            }

            if (accountDir is not null && wxCli is not null && await DecodeWithWxCliAsync(dat, accountDir, wxCli, log, cancellationToken))
            {
                decoded++;
                continue;
            }

            if (DecodeWithXor(dat))
            {
                decoded++;
                log($"已解密图片（XOR）：{Path.GetFileName(dat)}");
            }
        }

        if (decoded > 0) log($"已解密 {decoded} 张 .dat 图片");
        return decoded;
    }

    public static byte[]? TryDecodeInline(byte[] data)
    {
        for (var key = 0; key <= 255; key++)
        {
            var sample = XorDecode(data, (byte)key);
            if (ImageExporter.SniffImageMime(sample) is not null) return sample;
        }
        return null;
    }

    private static string? ExistingDecodedImage(string baseName, string dir)
    {
        foreach (var ext in new[] { "jpg", "jpeg", "png", "gif", "webp" })
        {
            var path = Path.Combine(dir, $"{baseName}.{ext}");
            if (File.Exists(path)) return path;
        }
        return null;
    }

    private static async Task<bool> DecodeWithWxCliAsync(
        string datPath, string accountDir, string wxCli, Action<string> log, CancellationToken cancellationToken)
    {
        var outPath = Path.Combine(Path.GetDirectoryName(datPath)!, $"{Path.GetFileNameWithoutExtension(datPath)}.jpg");
        var psi = new ProcessStartInfo
        {
            FileName = wxCli,
            Arguments = $"decode-image \"{datPath}\" -d \"{accountDir}\" -o \"{outPath}\"",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        try
        {
            using var process = Process.Start(psi);
            if (process is null) return false;
            await process.WaitForExitAsync(cancellationToken);
            if (File.Exists(outPath) && new FileInfo(outPath).Length > 0)
            {
                log($"已解密图片：{Path.GetFileName(datPath)}");
                return true;
            }
        }
        catch
        {
            return false;
        }
        return false;
    }

    private static bool DecodeWithXor(string datPath)
    {
        var data = File.ReadAllBytes(datPath);
        var decoded = TryDecodeInline(data);
        if (decoded is null || ImageExporter.SniffImageMime(decoded) is not { } mime) return false;

        var ext = mime switch
        {
            "image/png" => "png",
            "image/gif" => "gif",
            "image/webp" => "webp",
            _ => "jpg"
        };
        var outPath = Path.Combine(Path.GetDirectoryName(datPath)!, $"{Path.GetFileNameWithoutExtension(datPath)}.{ext}");
        File.WriteAllBytes(outPath, decoded);
        return true;
    }

    private static byte[] XorDecode(byte[] data, byte key) => data.Select(b => (byte)(b ^ key)).ToArray();

    public static string? LocateWeChatAccountDir()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var roots = new[]
        {
            Path.Combine(home, "Documents", "xwechat_files"),
            Path.Combine(home, "xwechat_files"),
        };

        string? best = null;
        var bestTime = DateTime.MinValue;
        foreach (var root in roots.Where(Directory.Exists))
        {
            foreach (var entry in Directory.EnumerateDirectories(root))
            {
                if (Path.GetFileName(entry) == "all_users") continue;
                var msgDir = Path.Combine(entry, "msg");
                if (!Directory.Exists(msgDir)) continue;
                var time = Directory.GetLastWriteTimeUtc(entry);
                if (time <= bestTime) continue;
                bestTime = time;
                best = entry;
            }
        }
        return best;
    }
}
