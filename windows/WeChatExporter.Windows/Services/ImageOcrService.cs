using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Windows.Media.Ocr;
using Windows.Storage;
using Windows.Storage.Streams;

namespace WeChatExporter.Services;

/// <summary>
/// 图片消息 OCR（本地离线）：Windows.Media.Ocr（Win10/11 内置，无需联网）。
/// 结果写入与图片同目录的 <c>&lt;文件名&gt;.ocr.txt</c> 侧车文件，HTML 生成时读取展示。
/// </summary>
public static class ImageOcrService
{
    /// <summary>OCR 侧车文件后缀。</summary>
    public const string SidecarSuffix = ".ocr.txt";

    private static readonly HashSet<string> ImageExtensions =
        new(StringComparer.OrdinalIgnoreCase) { "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "tiff" };

    /// <summary>递归收集目录下全部图片（去重，不含侧车）。</summary>
    public static List<string> CollectImages(string rootDir)
    {
        var result = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var root in new[] { Path.Combine(rootDir, "media"), rootDir })
        {
            if (!Directory.Exists(root)) continue;
            foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
            {
                if (!ImageExtensions.Contains(Path.GetExtension(file).TrimStart('.'))) continue;
                if (file.EndsWith(SidecarSuffix, StringComparison.OrdinalIgnoreCase)) continue;
                if (seen.Add(file)) result.Add(file);
            }
        }
        return result;
    }

    /// <summary>批量 OCR 目录内全部图片（幂等：已有侧车的跳过）。返回 (成功数, 跳过数)。</summary>
    public static (int Ok, int Skipped) OcrAll(string dir, Action<string>? log)
    {
        var files = CollectImages(dir);
        if (files.Count == 0)
        {
            log?.Invoke("未发现图片文件，跳过 OCR");
            return (0, 0);
        }

        log?.Invoke($"开始图片 OCR {files.Count} 张（本地离线 Windows OCR）…");
        var ok = 0;
        var skipped = 0;
        for (var i = 0; i < files.Count; i++)
        {
            var file = files[i];
            if (OcrTextFor(file) != null)
            {
                skipped++;
                continue;
            }
            log?.Invoke($"OCR {i + 1}/{files.Count}：{Path.GetFileName(file)}");
            string? text;
            try
            {
                text = RecognizeText(file);
            }
            catch (Exception ex)
            {
                log?.Invoke($"  OCR 失败：{Path.GetFileName(file)}（{ex.Message}）");
                continue;
            }
            if (string.IsNullOrWhiteSpace(text)) continue;
            try
            {
                File.WriteAllText(SidecarPathFor(file), text!.Trim(), new UTF8Encoding(false));
                ok++;
                log?.Invoke($"  → 已生成 {Path.GetFileName(SidecarPathFor(file))}");
            }
            catch (Exception ex)
            {
                log?.Invoke($"  写入失败：{ex.Message}");
            }
        }
        log?.Invoke($"图片 OCR 完成：成功 {ok} 张、跳过 {skipped} 张（已有结果）");
        return (ok, skipped);
    }

    /// <summary>单图识别（Windows.Media.Ocr，离线；中文识别需系统装有中文 OCR 语言包，默认系统语言）。</summary>
    public static string? RecognizeText(string imagePath)
    {
        OcrEngine? engine = OcrEngine.TryCreateFromUserProfileLanguages();
        if (engine is null)
        {
            var lang = System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName;
            engine = OcrEngine.TryCreateFromLanguage(new Windows.Globalization.Language(lang));
        }
        if (engine is null)
        {
            throw new InvalidOperationException("系统无可用 OCR 引擎（可在「时间和语言 → 语音」安装语言包）");
        }

        var file = Windows.Storage.StorageFile.GetFileFromPathAsync(imagePath)
            .AsTask().GetAwaiter().GetResult();
        using var stream = file.OpenReadAsync()
            .AsTask().GetAwaiter().GetResult();
        var decoder = Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream)
            .AsTask().GetAwaiter().GetResult();
        var bitmap = decoder.GetSoftwareBitmapAsync()
            .AsTask().GetAwaiter().GetResult();
        var result = engine.RecognizeAsync(bitmap).AsTask().GetAwaiter().GetResult();
        return result?.Text;
    }

    /// <summary>图片文件对应的 OCR 侧车路径：同目录 <c>&lt;原文件名&gt;.ocr.txt</c>。</summary>
    public static string SidecarPathFor(string imageUrl)
        => Path.Combine(Path.GetDirectoryName(imageUrl) ?? imageUrl, Path.GetFileName(imageUrl) + SidecarSuffix);

    /// <summary>读取侧车内容（不存在或空返回 null）。</summary>
    public static string? OcrTextFor(string imageUrl)
    {
        var path = SidecarPathFor(imageUrl);
        if (!File.Exists(path)) return null;
        var text = File.ReadAllText(path).Trim();
        return text.Length == 0 ? null : text;
    }
}
