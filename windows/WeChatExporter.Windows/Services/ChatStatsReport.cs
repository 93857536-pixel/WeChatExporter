using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Web;

namespace WeChatExporter.Services;

/// <summary>
/// 聊天统计报告：解析导出的 chat.json，聚合消息量/时段/月度趋势/发言排行/媒体构成，
/// 生成单文件 HTML（纯内嵌 CSS + 内联条形图，无外部依赖，可离线打开）。
/// </summary>
public static class ChatStatsReport
{
    private static readonly TimeZoneInfo Shanghai = TimeZoneInfo.FindSystemTimeZoneById("China Standard Time");
    private static readonly HashSet<string> ImageExts =
        new(StringComparer.OrdinalIgnoreCase) { "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff" };
    private static readonly HashSet<string> AudioExts =
        new(StringComparer.OrdinalIgnoreCase) { "silk", "pcm", "wav", "mp3", "m4a", "aac", "amr", "ogg" };
    private static readonly HashSet<string> VideoExts =
        new(StringComparer.OrdinalIgnoreCase) { "mp4", "mov", "avi" };

    /// <summary>从 sourceDir 的 chat.json 生成统计报告 HTML，返回输出文件路径；无数据返回 null。</summary>
    public static string? WriteReport(string sourceDir, string contactName, string destDir, Action<string>? log)
    {
        var jsonPath = Path.Combine(sourceDir, "chat.json");
        if (!File.Exists(jsonPath))
        {
            log?.Invoke("未找到 chat.json，跳过统计报告");
            return null;
        }

        List<JsonElement> rows;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(jsonPath));
            rows = doc.RootElement.ValueKind switch
            {
                JsonValueKind.Array => doc.RootElement.EnumerateArray().ToList(),
                JsonValueKind.Object when doc.RootElement.TryGetProperty("items", out var items)
                    => items.EnumerateArray().ToList(),
                JsonValueKind.Object when doc.RootElement.TryGetProperty("messages", out var messages)
                    => messages.EnumerateArray().ToList(),
                JsonValueKind.Object when doc.RootElement.TryGetProperty("results", out var results)
                    => results.EnumerateArray().ToList(),
                _ => []
            };
        }
        catch (Exception ex)
        {
            log?.Invoke($"chat.json 解析失败，跳过统计报告：{ex.Message}");
            return null;
        }

        if (rows.Count == 0)
        {
            log?.Invoke("聊天记录为空，跳过统计报告");
            return null;
        }

        // MARK: 聚合
        var timestamps = new List<DateTime>();
        var senderCounts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var hourBuckets = new int[24];
        var monthCounts = new Dictionary<string, int>(StringComparer.Ordinal);
        var monthOrder = new List<string>();
        var mediaKinds = new Dictionary<string, int>(StringComparer.Ordinal);
        var totalMedia = 0;

        foreach (var row in rows)
        {
            var source = row.ValueKind == JsonValueKind.Object && row.TryGetProperty("message", out var m) ? m : row;

            long? ts = GetInt(source, "create_time", "timestamp") ?? GetInt(row, "create_time", "timestamp");
            if (ts is > 0)
            {
                var unix = ts.Value;
                if (unix > 10_000_000_000_000L) unix /= 1000; // 毫秒
                var utc = DateTimeOffset.FromUnixTimeSeconds(unix).UtcDateTime;
                var local = TimeZoneInfo.ConvertTimeFromUtc(utc, Shanghai);
                timestamps.Add(local);
                hourBuckets[local.Hour]++;
                var month = local.ToString("yyyy-MM");
                if (!monthCounts.ContainsKey(month)) monthOrder.Add(month);
                monthCounts[month] = monthCounts.TryGetValue(month, out var mc) ? mc + 1 : 1;
            }

            var sender = GetString(row, "sender_display_name", "sender", "from", "display_name")
                ?? GetString(source, "sender_display_name", "sender")
                ?? "未知";
            senderCounts[sender] = senderCounts.TryGetValue(sender, out var sc) ? sc + 1 : 1;

            var media = GetMedia(row, source);
            if (media.Count > 0)
            {
                totalMedia += media.Count;
                foreach (var file in media)
                {
                    var ext = Path.GetExtension(file).TrimStart('.').ToLowerInvariant();
                    var kind = ImageExts.Contains(ext) ? "图片"
                        : AudioExts.Contains(ext) ? "语音"
                        : VideoExts.Contains(ext) ? "视频"
                        : "其他";
                    mediaKinds[kind] = mediaKinds.TryGetValue(kind, out var kc) ? kc + 1 : 1;
                }
            }
        }

        var totalMessages = rows.Count;
        var topSenders = senderCounts.OrderByDescending(kv => kv.Value).Take(8).ToList();
        var peakMonth = monthCounts.OrderByDescending(kv => kv.Value).FirstOrDefault();
        var totalChars = 0;
        foreach (var row in rows)
        {
            var source = row.ValueKind == JsonValueKind.Object && row.TryGetProperty("message", out var m) ? m : row;
            totalChars += (GetString(row, "snippet", "content", "text", "message", "summary")
                ?? GetString(source, "snippet", "content", "text") ?? "").Length;
        }
        var avgLen = totalMessages > 0 ? totalChars / totalMessages : 0;
        var earliest = timestamps.Count > 0 ? timestamps.Min() : (DateTime?)null;
        var latest = timestamps.Count > 0 ? timestamps.Max() : (DateTime?)null;

        // MARK: 渲染 HTML
        var now = TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, Shanghai);
        var html = new StringBuilder();
        html.Append("<!DOCTYPE html>\n<html lang=\"zh-CN\"><head><meta charset=\"utf-8\">");
        html.Append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">");
        html.Append($"<title>{HtmlEscape(contactName.Length == 0 ? "聊天记录统计" : contactName + " 统计")}</title>");
        html.Append($"<style>{Styles}</style></head><body>");
        html.Append(Watermark.HtmlOverlay());
        html.Append($"<header><h1>📊 {HtmlEscape(contactName.Length == 0 ? "聊天记录" : contactName)} · 统计报告</h1>");
        html.Append($"<p class=\"sub\">数据范围：{(earliest?.ToString("yyyy-MM-dd HH:mm") ?? "—")} 至 {latest?.ToString("yyyy-MM-dd HH:mm") ?? "—"}　·　共 {totalMessages} 条消息　·　生成于 {now:yyyy-MM-dd HH:mm}</p></header>");

        // 概览卡片
        html.Append($"<section class=\"cards\"><div class=\"card\"><div class=\"num\">{totalMessages}</div><div>消息总数</div></div>");
        html.Append($"<div class=\"card\"><div class=\"num\">{totalMedia}</div><div>媒体附件</div></div>");
        html.Append($"<div class=\"card\"><div class=\"num\">{senderCounts.Count}</div><div>参与者</div></div>");
        html.Append($"<div class=\"card\"><div class=\"num\">{avgLen}</div><div>平均字数/条</div></div></section>");

        // 发言排行
        html.Append("<section><h2>发言排行</h2>");
        if (topSenders.Count > 0)
        {
            var maxCount = topSenders[0].Value;
            foreach (var kv in topSenders)
            {
                var pct = Math.Max(3, (int)Math.Round((double)kv.Value / maxCount * 100));
                var share = totalMessages > 0 ? $"{(double)kv.Value / totalMessages * 100:F1}%" : "0%";
                html.Append($"<div class=\"bar-row\"><span class=\"bar-label\">{HtmlEscape(kv.Key)}</span>");
                html.Append($"<div class=\"bar-track\"><div class=\"bar\" style=\"width:{pct}%\"></div></div>");
                html.Append($"<span class=\"bar-value\">{kv.Value}（{share}）</span></div>");
            }
        }
        else
        {
            html.Append("<p class=\"sub\">无发言数据</p>");
        }
        html.Append("</section>");

        // 时段分布
        html.Append("<section><h2>24 小时活跃分布</h2><div class=\"hours\">");
        var maxHour = hourBuckets.Max();
        for (var h = 0; h < 24; h++)
        {
            var c = hourBuckets[h];
            var height = maxHour > 0 ? (int)Math.Round((double)c / maxHour * 100) : 0;
            html.Append($"<div class=\"hour-cell\"><div class=\"hour-bar\" style=\"height:{height}%\" title=\"{c} 条\"></div>");
            html.Append($"<span>{h}时</span></div>");
        }
        html.Append("</div></section>");

        // 月度趋势
        html.Append("<section><h2>月度消息量</h2>");
        if (monthOrder.Count > 0)
        {
            var sortedMonths = monthOrder.OrderBy(m => m).ToList();
            var maxMonth = monthCounts.Values.Max();
            var peakKey = peakMonth.Key;
            foreach (var m in sortedMonths)
            {
                var c = monthCounts[m];
                var w = Math.Max(2, (int)Math.Round((double)c / maxMonth * 100));
                var isPeak = m == peakKey;
                html.Append($"<div class=\"bar-row\"><span class=\"bar-label\">{HtmlEscape(m)}{(isPeak ? " 🏆" : "")}</span>");
                html.Append($"<div class=\"bar-track\"><div class=\"bar\" style=\"width:{w}%\"></div></div>");
                html.Append($"<span class=\"bar-value\">{c}</span></div>");
            }
        }
        else
        {
            html.Append("<p class=\"sub\">无时间数据</p>");
        }
        html.Append("</section>");

        // 媒体构成
        html.Append("<section><h2>媒体构成</h2>");
        if (mediaKinds.Count > 0)
        {
            foreach (var kv in mediaKinds.OrderByDescending(kv => kv.Value))
            {
                var pct = totalMedia > 0 ? $"{(double)kv.Value / totalMedia * 100:F1}%" : "0%";
                html.Append($"<p>· {HtmlEscape(kv.Key)}：{kv.Value}（{pct}）</p>");
            }
        }
        else
        {
            html.Append("<p class=\"sub\">本次导出无媒体附件</p>");
        }
        html.Append("</section>");

        html.Append($"<footer>由 WeChatExporter 本地生成 · 数据未离开你的设备{Watermark.HtmlFooter()}</footer></body></html>");

        var safeName = SanitizeFilename(contactName.Length == 0 ? "统计报告" : contactName);
        var stamp = now.ToString("yyyyMMdd-HHmmss");
        var outPath = Path.Combine(destDir, $"{safeName}_统计_{stamp}.html");
        try
        {
            File.WriteAllText(outPath, html.ToString(), new UTF8Encoding(false));
            log?.Invoke($"统计报告已生成：{Path.GetFileName(outPath)}");
            return outPath;
        }
        catch (Exception ex)
        {
            log?.Invoke($"统计报告写入失败：{ex.Message}");
            return null;
        }
    }

    // MARK: - 工具函数（与 SingleFileExporter 保持一致的解析口径）

    private static int? GetInt(JsonElement el, params string[] keys)
    {
        if (el.ValueKind != JsonValueKind.Object) return null;
        foreach (var key in keys)
        {
            if (!el.TryGetProperty(key, out var v)) continue;
            if (v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var n)) return n;
            if (v.ValueKind == JsonValueKind.String && int.TryParse(v.GetString(), out var s)) return s;
        }
        return null;
    }

    private static string? GetString(JsonElement el, params string[] keys)
    {
        if (el.ValueKind != JsonValueKind.Object) return null;
        foreach (var key in keys)
        {
            if (!el.TryGetProperty(key, out var v)) continue;
            if (v.ValueKind == JsonValueKind.String)
            {
                var s = v.GetString();
                if (!string.IsNullOrEmpty(s)) return s;
            }
        }
        return null;
    }

    private static List<string> GetMedia(JsonElement row, JsonElement source)
    {
        var media = new List<string>();
        foreach (var el in new[] { row, source })
        {
            if (el.ValueKind == JsonValueKind.Object
                && el.TryGetProperty("media_files", out var mf)
                && mf.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in mf.EnumerateArray())
                {
                    var s = item.GetString();
                    if (!string.IsNullOrEmpty(s)) media.Add(s);
                }
                if (media.Count > 0) break;
            }
        }
        return media;
    }

    private static string SanitizeFilename(string name)
    {
        var cleaned = Regex.Replace(name, @"[/\\:?*""<>|]", "_").Replace(".", " ");
        return string.IsNullOrWhiteSpace(cleaned) ? "聊天记录" : cleaned;
    }

    private static string HtmlEscape(string s) => HttpUtility.HtmlEncode(s);

    private const string Styles = """
    :root { --bg: #0b1026; --card: rgba(255,255,255,0.05); --cyan: #00f5ff; --purple: #7b61ff; --text: #f0f8ff; --sub: #9aa7c7; }
    * { box-sizing: border-box; }
    body { margin: 0; padding: 32px 16px; background: radial-gradient(1200px 600px at 50% -100px, #1b2a5e 0%, var(--bg) 60%); color: var(--text); font-family: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif; }
    header, section { max-width: 860px; margin: 0 auto; }
    header { text-align: center; margin-bottom: 28px; }
    h1 { font-size: 26px; margin: 0 0 8px; }
    .sub { color: var(--sub); font-size: 13px; }
    .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px; margin-bottom: 28px; }
    .card { background: var(--card); border: 1px solid rgba(0,245,255,0.18); border-radius: 14px; padding: 18px; text-align: center; }
    .card .num { font-size: 30px; font-weight: 700; color: var(--cyan); }
    section { background: var(--card); border: 1px solid rgba(0,245,255,0.14); border-radius: 14px; padding: 20px; margin-bottom: 20px; }
    h2 { font-size: 17px; margin: 0 0 14px; color: var(--cyan); }
    .bar-row { display: flex; align-items: center; gap: 10px; margin: 8px 0; font-size: 13px; }
    .bar-label { width: 120px; text-align: right; color: var(--text); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bar-track { flex: 1; height: 14px; background: rgba(255,255,255,0.07); border-radius: 7px; overflow: hidden; }
    .bar { height: 100%; background: linear-gradient(90deg, var(--cyan), var(--purple)); border-radius: 7px; }
    .bar-value { width: 90px; color: var(--sub); }
    .hours { display: grid; grid-template-columns: repeat(12, 1fr); gap: 6px; }
    .hour-cell { text-align: center; font-size: 11px; color: var(--sub); }
    .hour-bar { margin: 0 auto 4px; width: 70%; min-height: 3px; height: 60px; display: flex; align-items: flex-end; background: linear-gradient(180deg, var(--cyan), var(--purple)); border-radius: 4px 4px 0 0; }
    footer { text-align: center; color: var(--sub); font-size: 12px; margin-top: 24px; }
    """;
}
