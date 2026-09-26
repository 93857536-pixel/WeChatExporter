using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace WeChatExporter.Services;

/// <summary>
/// 语音消息转文字（本地离线）：SILK → WAV(silk2wav.exe 内置解码) → whisper.cpp 转写。
/// 结果写入与语音同目录的 <c>&lt;文件名&gt;.transcript.txt</c> 侧车文件，HTML 生成时读取展示。
/// 缺少 whisper-cli 或模型时静默跳过，不影响导出。
/// </summary>
public static class VoiceTranscriber
{
    /// <summary>转写侧车文件后缀（与语音文件同目录、同名 + 后缀）。</summary>
    public const string SidecarSuffix = ".transcript.txt";

    private static readonly HashSet<string> AudioExtensions =
        new(StringComparer.OrdinalIgnoreCase) { "silk", "pcm", "wav", "m4a", "mp3", "aac", "amr", "ogg" };

    public static string ModelDownloadUrl =>
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-multi.bin";

    private const string ModelDirName = ".whisper-cpp-models";

    public static string ModelDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ModelDirName);

    /// <summary>是否具备转写能力（whisper-cli + 模型；silk 文件另需 silk2wav）。</summary>
    public static bool IsAvailable()
    {
        return LocateWhisperCli() != null && LocateWhisperModel() != null;
    }

    /// <summary>silk2wav 解码器（随应用内置）是否存在。</summary>
    public static string? LocateSilk2wav()
    {
        var bundled = Path.Combine(AppContext.BaseDirectory, "silk2wav.exe");
        if (File.Exists(bundled)) return bundled;
        return null;
    }

    /// <summary>定位 whisper-cli（安装目录 → 用户目录 → PATH）。</summary>
    public static string? LocateWhisperCli()
    {
        var candidates = new[]
        {
            Path.Combine(AppContext.BaseDirectory, "whisper-cli.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "whisper-cli", "whisper-cli.exe"),
        };
        foreach (var c in candidates)
            if (File.Exists(c)) return c;
        return FindOnPath("whisper-cli");
    }

    /// <summary>定位 whisper 模型（用户目录下 %USERPROFILE%\.whisper-cpp-models，按优先级匹配）。</summary>
    public static string? LocateWhisperModel()
    {
        var preferred = new[]
        {
            "ggml-base-multi.bin", "ggml-small-multi.bin", "ggml-small.bin",
            "ggml-base.en.bin", "ggml-medium.bin", "ggml-base.bin",
        };
        if (!Directory.Exists(ModelDirectory)) return null;
        foreach (var name in preferred)
        {
            var p = Path.Combine(ModelDirectory, name);
            if (File.Exists(p)) return p;
        }
        return null;
    }

    /// <summary>递归收集目录下全部语音文件（去重）。</summary>
    public static List<string> CollectAudioFiles(string rootDir)
    {
        var result = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var root in new[] { Path.Combine(rootDir, "media"), rootDir })
        {
            if (!Directory.Exists(root)) continue;
            foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
            {
                if (!AudioExtensions.Contains(Path.GetExtension(file).TrimStart('.'))) continue;
                if (file.EndsWith(SidecarSuffix, StringComparison.OrdinalIgnoreCase)) continue;
                if (seen.Add(file)) result.Add(file);
            }
        }
        return result;
    }

    /// <summary>批量转写目录内全部语音文件（幂等：已有侧车的跳过）。返回成功数。</summary>
    public static int TranscribeAll(string dir, Action<string>? log)
    {
        var cli = LocateWhisperCli();
        var model = LocateWhisperModel();
        if (cli == null || model == null)
        {
            log?.Invoke("跳过语音转写：未检测到 whisper.cpp（whisper-cli.exe 或模型缺失）。可在「设置 → 语音转文字」中安装。");
            return 0;
        }
        var silk2wav = LocateSilk2wav();

        var files = CollectAudioFiles(dir);
        if (files.Count == 0)
        {
            log?.Invoke("未发现语音文件，跳过转写");
            return 0;
        }

        log?.Invoke($"开始语音转写 {files.Count} 条（本地离线：{Path.GetFileName(model)}）…");
        var ok = 0;
        var skipped = 0;
        var index = 0;
        foreach (var file in files)
        {
            index++;
            if (TranscriptFor(file) != null)
            {
                skipped++;
                continue;
            }
            log?.Invoke($"转写 {index}/{files.Count}：{Path.GetFileName(file)}");
            try
            {
                var text = Transcribe(file, cli, model, silk2wav, log);
                if (string.IsNullOrWhiteSpace(text))
                {
                    log?.Invoke($"  无可识别语音内容：{Path.GetFileName(file)}");
                    continue;
                }
                File.WriteAllText(SidecarPathFor(file), text.Trim(), new UTF8Encoding(false));
                ok++;
                log?.Invoke($"  → 已生成 {Path.GetFileName(SidecarPathFor(file))}");
            }
            catch (Exception ex)
            {
                log?.Invoke($"  转写失败：{Path.GetFileName(file)}（{ex.Message}）");
            }
        }
        log?.Invoke($"语音转写完成：成功 {ok} 条、跳过 {skipped} 条（已有结果）");
        return ok;
    }

    /// <summary>单文件转写：silk 先解码为 WAV，其余音频直接给 whisper.cpp。</summary>
    public static string Transcribe(string file, string cli, string model, string? silk2wav, Action<string>? log)
    {
        var ext = Path.GetExtension(file).TrimStart('.').ToLowerInvariant();
        var source = file;
        string? workDir = null;
        try
        {
            if (ext == "silk")
            {
                if (silk2wav == null)
                    throw new InvalidOperationException("缺少内置 silk2wav 解码器，无法解码 SILK 语音");
                workDir = Path.Combine(Path.GetTempPath(), $"wxe-asr-{Guid.NewGuid():N}");
                Directory.CreateDirectory(workDir);
                var wav = Path.Combine(workDir, Path.GetFileNameWithoutExtension(file) + ".wav");
                RunTool(silk2wav, new[] { file, wav });
                if (!File.Exists(wav))
                    throw new InvalidOperationException($"SILK 解码失败：{Path.GetFileName(file)}");
                source = wav;
            }

            var stdout = RunTool(cli, new[] { "-m", model, "-l", "auto", "-f", source, "-nt" });
            // whisper-cli -nt：识别文本走 stdout，进度/计时走 stderr
            var lines = stdout.Split('\n')
                .Select(l => l.Trim())
                .Where(l => l.Length > 0
                             && !l.StartsWith("read_audio_data", StringComparison.Ordinal)
                             && !l.StartsWith("main:", StringComparison.Ordinal)
                             && !l.StartsWith("whisper_", StringComparison.Ordinal))
                .ToList();
            return string.Join("\n", lines);
        }
        finally
        {
            if (workDir != null)
            {
                try { Directory.Delete(workDir, recursive: true); } catch { /* ignore */ }
            }
        }
    }

    /// <summary>语音文件对应的转写侧车路径：同目录 <c>&lt;原文件名&gt;.transcript.txt</c>。</summary>
    public static string SidecarPathFor(string audioFile)
        => Path.Combine(Path.GetDirectoryName(audioFile) ?? audioFile, Path.GetFileName(audioFile) + SidecarSuffix);

    /// <summary>读取侧车内容（不存在或空返回 null）。</summary>
    public static string? TranscriptFor(string audioFile)
    {
        var url = SidecarPathFor(audioFile);
        if (!File.Exists(url)) return null;
        var text = File.ReadAllText(url).Trim();
        return text.Length == 0 ? null : text;
    }

    /// <summary>下载 whisper 模型（约 141MB，HuggingFace ggml 官方）。</summary>
    public static Task<(bool Ok, string Message)> DownloadModelAsync(
        Action<double, string>? progress, Action<string>? log, CancellationToken ct = default)
    {
        return Task.Run(async () =>
        {
            if (LocateWhisperModel() is { } existing)
            {
                log?.Invoke($"whisper 模型已存在：{existing}");
                return (true, existing);
            }
            Directory.CreateDirectory(ModelDirectory);
            var dest = Path.Combine(ModelDirectory, "ggml-base-multi.bin");
            log?.Invoke("开始下载 whisper 模型 ggml-base-multi.bin（约 141MB）…");
            using var http = new System.Net.Http.HttpClient();
            using var stream = await http.GetStreamAsync(ModelDownloadUrl, ct);
            using var fs = File.Create(dest);
            var buffer = new byte[1024 * 256];
            long total = 0;
            while (true)
            {
                int read;
                try { read = await stream.ReadAsync(buffer, ct); }
                catch (OperationCanceledException) { File.Delete(dest); throw; }
                if (read <= 0) break;
                fs.Write(buffer, 0, read);
                total += read;
                progress?.Invoke(Math.Min(total / 148_000_000.0, 1.0), $"{total / 1048576.0:F0} / ~141 MB");
            }
            log?.Invoke($"whisper 模型已下载：{dest}");
            return (true, dest);
        }, ct);
    }

    // MARK: - 工具调用

    private static string RunTool(string executable, string[] args)
    {
        var psi = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var proc = Process.Start(psi) ?? throw new InvalidOperationException("无法启动 " + Path.GetFileName(executable));
        var stdout = proc.StandardOutput.ReadToEnd();
        var stderr = proc.StandardError.ReadToEnd();
        proc.WaitForExit();
        if (proc.ExitCode != 0)
        {
            var detail = (stderr + stdout).Trim();
            throw new InvalidOperationException($"{Path.GetFileName(executable)} 退出码 {proc.ExitCode}：{detail[..Math.Min(detail.Length, 200)]}");
        }
        return stdout;
    }

    private static string? FindOnPath(string name)
    {
        var pathVar = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in pathVar.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(dir, name + ".exe");
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }
}
