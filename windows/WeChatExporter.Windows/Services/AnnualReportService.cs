using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace WeChatExporter.Services;

/// <summary>
/// 年度报告（SPEC §5）：扫描导出根目录所有会话的 chat.json，
/// 生成单文件暗色科技风 HTML：概览卡 + 月度柱状 + 月×星期热力图 + 词频 Top30 + 跨会话排行 + 24 小时分布。
/// 与 macOS Services/AnnualReportService.swift 对称实现（产物/样式/数据口径一致）。
/// </summary>
public static class AnnualReportService
{
    private static readonly TimeZoneInfo Shanghai = TimeZoneInfo.FindSystemTimeZoneById("China Standard Time");

    private static readonly HashSet<string> Stopwords = new(StringComparer.Ordinal)
    {
        "的", "了", "我", "你", "他", "她", "它", "我们", "你们", "是", "在", "有", "和", "就",
        "都", "也", "还", "会", "这", "那", "个", "啊", "呀", "哦", "嗯", "呢", "吗", "吧",
        "被", "把", "让", "对", "跟", "不", "没", "么", "什么", "这个", "那个", "一个",
        "the", "a", "an", "is", "are", "to", "of", "and", "in", "on", "at", "it", "this", "that",
        "ok", "haha", "哈哈", "好的", "嗯嗯", "收到", "可以", "不用", "谢谢",
    };

    /// <summary>生成年度报告，返回输出文件路径；无数据返回 null。</summary>
    public static string? Write(string baseDir, Action<string>? log)
    {
        var jsonFiles = new List<string>();
        if (Directory.Exists(baseDir))
        {
            try { jsonFiles = Directory.EnumerateFiles(baseDir, "chat.json", SearchOption.AllDirectories).ToList(); }
            catch { /* ignore */ }
        }

        var rows = new List<JsonNode>();
        var sessionNames = new List<string>();
        foreach (var jsonPath in jsonFiles)
        {
            List<JsonNode> part;
            try
            {
                var root = JsonNode.Parse(File.ReadAllText(jsonPath));
                if (root is JsonArray arr) part = arr.Select(n => n!).ToList();
                else if (root is JsonObject obj)
                {
                    part = [];
                    foreach (var key in new[] { "items", "messages", "results" })
                    {
                        if (obj[key] is JsonArray a) { part = a.Select(n => n!).ToList(); break; }
                    }
                }
                else part = [];
            }
            catch { continue; }

            if (part.Count > 0) sessionNames.Add(Path.GetFileName(Path.GetDirectoryName(jsonPath)) ?? "");
            rows.AddRange(part);
        }

        if (rows.Count == 0)
        {
            log?.Invoke("年度报告：无消息数据，跳过");
            return null;
        }

        // MARK: 聚合
        var monthCounts = new Dictionary<string, int>(StringComparer.Ordinal);
        var weekdayMonth = new Dictionary<string, Dictionary<int, int>>(StringComparer.Ordinal); // "yyyy-MM" -> [weekday(0=周一): count]
        var hourBuckets = new int[24];
        var senderCounts = new Dictionary<string, int>(StringComparer.Ordinal);
        var daySet = new HashSet<string>(StringComparer.Ordinal);
        var wordFreq = new Dictionary<string, int>(StringComparer.Ordinal);
        var totalMedia = 0;
        var years = new HashSet<int>();

        foreach (var row in rows)
        {
            var source = row is JsonObject o && o["message"] is JsonObject msg ? msg : row;
            var ts = GetInt(source, "create_time", "timestamp") ?? GetInt(row, "create_time", "timestamp");
            if (ts is { } t && t > 0)
            {
                t = NormalizeTs(t);
                var local = TimeZoneInfo.ConvertTimeFromUtc(DateTimeOffset.FromUnixTimeSeconds(t).UtcDateTime, Shanghai);
                years.Add(local.Year);
                var monthKey = local.ToString("yyyy-MM");
                monthCounts[monthKey] = monthCounts.TryGetValue(monthKey, out var mc) ? mc + 1 : 1;
                daySet.Add(local.ToString("yyyy-MM-dd"));
                hourBuckets[local.Hour]++;
                var weekday = ((int)local.DayOfWeek + 6) % 7; // 0=周一
                if (!weekdayMonth.TryGetValue(monthKey, out var wm)) { wm = new Dictionary<int, int>(); weekdayMonth[monthKey] = wm; }
                wm[weekday] = wm.TryGetValue(weekday, out var wc) ? wc + 1 : 1;
            }

            var sender = GetString(row, "sender_display_name", "sender", "from", "display_name")
                ?? GetString(source, "sender_display_name", "sender") ?? "未知";
            senderCounts[sender] = senderCounts.TryGetValue(sender, out var sc) ? sc + 1 : 1;

            var text = GetString(row, "snippet", "content", "text", "message", "summary")
                ?? GetString(source, "content", "text") ?? "";
            foreach (var w in Tokenize(text))
                wordFreq[w] = wordFreq.TryGetValue(w, out var wc) ? wc + 1 : 1;

            var media = GetMedia(row, source);
            totalMedia += media.Count;
        }

        var peakMonth = monthCounts.OrderByDescending(kv => kv.Value).FirstOrDefault().Key ?? "";
        var topSenders = senderCounts.OrderByDescending(kv => kv.Value).Take(10).ToList();
        var topWords = wordFreq.OrderByDescending(kv => kv.Value).Where(kv => kv.Value > 1).Take(30).ToList();
        var maxMonth = monthCounts.Values.DefaultIfEmpty(1).Max();
        var maxWeek = weekdayMonth.Values.SelectMany(d => d.Values).DefaultIfEmpty(1).Max();
        var maxSender = topSenders.FirstOrDefault().Value;
        if (maxSender == 0) maxSender = 1;
        var maxWord = topWords.FirstOrDefault().Value;
        if (maxWord == 0) maxWord = 1;
        var maxHour = hourBuckets.Max();
        if (maxHour == 0) maxHour = 1;
        var year = years.Count > 0 ? years.Max() : DateTime.Now.Year;

        // MARK: 数据内嵌 JSON（供页面交互；图表用 CSS 直渲染）
        var embedded = new Dictionary<string, object?>
        {
            ["year"] = year,
            ["sessions"] = sessionNames.Count,
            ["messages"] = rows.Count,
            ["media"] = totalMedia,
            ["activeDays"] = daySet.Count,
            ["peakMonth"] = peakMonth,
            ["monthCounts"] = monthCounts,
            ["weekdayMonth"] = weekdayMonth.ToDictionary(kv => kv.Key, kv => (object)kv.Value.ToDictionary(w => w.Key.ToString(), w => w.Value)),
            ["hours"] = Enumerable.Range(0, 24).ToDictionary(h => h.ToString(), h => hourBuckets[h]),
            ["topSenders"] = topSenders.Select(kv => (object)new Dictionary<string, object?> { ["name"] = kv.Key, ["count"] = kv.Value }).ToList(),
            ["topWords"] = topWords.Select(kv => (object)new Dictionary<string, object?> { ["word"] = kv.Key, ["count"] = kv.Value }).ToList(),
        };
        string json;
        try { json = JsonSerializer.Serialize(embedded); } catch { json = "{}"; }

        // MARK: 渲染
        var html = new StringBuilder();
        html.Append("<!DOCTYPE html>\n<html lang=\"zh-CN\"><head><meta charset=\"utf-8\">");
        html.Append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">");
        html.Append($"<title>{year} 微信聊天记录年度报告</title><style>").Append(Styles).Append("</style></head><body>");
        html.Append(Watermark.HtmlOverlay());
        html.Append($"<header><h1>📅 {year} 年度报告</h1>");
        html.Append($"<p class=\"sub\">{sessionNames.Count} 个会话 · {rows.Count} 条消息 · {daySet.Count} 个活跃天 · 峰值 {(peakMonth.Length == 0 ? "—" : peakMonth + " 🏆")}　·　生成于 {DateTime.Now:yyyy-MM-dd HH:mm}</p></header>");

        html.Append($"<section class=\"cards\"><div class=\"card\"><div class=\"num\">{sessionNames.Count}</div><div>会话</div></div>");
        html.Append($"<div class=\"card\"><div class=\"num\">{rows.Count}</div><div>消息总数</div></div>");
        html.Append($"<div class=\"card\"><div class=\"num\">{totalMedia}</div><div>媒体附件</div></div>");
        html.Append($"<div class=\"card\"><div class=\"num\">{daySet.Count}</div><div>活跃天</div></div>");
        html.Append($"<div class=\"card\"><div class=\"num\">{(peakMonth.Length == 0 ? "—" : peakMonth)}</div><div>峰值月份</div></div></section>");

        // 月度柱状
        html.Append("<section><h2>月度消息量</h2>");
        if (monthCounts.Count == 0)
        {
            html.Append("<p class=\"sub\">无时间数据</p>");
        }
        else
        {
            foreach (var m in monthCounts.Keys.OrderBy(m => m, StringComparer.Ordinal))
            {
                var c = monthCounts[m];
                var w = Math.Max(2, (int)((double)c / maxMonth * 100));
                var peak = m == peakMonth ? " 🏆" : "";
                html.Append($"<div class=\"bar-row\"><span class=\"bar-label\">{Escape(m)}{peak}</span>");
                html.Append($"<div class=\"bar-track\"><div class=\"bar\" style=\"width:{w}%\"></div></div>");
                html.Append($"<span class=\"bar-value\">{c}</span></div>");
            }
        }
        html.Append("</section>");

        // 月×星期热力图
        var months = monthCounts.Keys.OrderBy(m => m, StringComparer.Ordinal).ToList();
        html.Append("<section><h2>活跃热力图（月 × 星期）</h2>");
        if (months.Count == 0)
        {
            html.Append("<p class=\"sub\">无时间数据</p>");
        }
        else
        {
            html.Append("<div class=\"heat\"><div class=\"heat-header\"><div class=\"heat-month\"></div>");
            html.Append("<div class=\"heat-weekday\"><span>一</span><span>二</span><span>三</span><span>四</span><span>五</span><span>六</span><span>日</span></div></div>");
            foreach (var m in months)
            {
                html.Append($"<div class=\"heat-row\"><div class=\"heat-month\">{Escape(m)}</div>");
                for (var wd = 0; wd < 7; wd++)
                {
                    weekdayMonth.TryGetValue(m, out var wm);
                    var c = wm is not null && wm.TryGetValue(wd, out var cc) ? cc : 0;
                    var alpha = maxWeek > 0 ? Math.Min(1.0, 0.15 + (double)c / maxWeek * 0.85) : 0.15;
                    html.Append($"<div class=\"heat-cell\" style=\"background:rgba(0,245,255,{alpha:F2})\" title=\"{Escape(m)} 周{wd} · {c} 条\"></div>");
                }
                html.Append("</div>");
            }
            html.Append("</div>");
        }
        html.Append("</section>");

        // 词频
        html.Append($"<section><h2>高频词 Top {topWords.Count}</h2>");
        if (topWords.Count == 0)
        {
            html.Append("<p class=\"sub\">暂无足够词频数据</p>");
        }
        else
        {
            foreach (var (word, count) in topWords)
            {
                var w = Math.Max(3, (int)((double)count / maxWord * 100));
                html.Append($"<div class=\"bar-row\"><span class=\"bar-label\">{Escape(word)}</span>");
                html.Append($"<div class=\"bar-track\"><div class=\"bar\" style=\"width:{w}%\"></div></div>");
                html.Append($"<span class=\"bar-value\">{count}</span></div>");
            }
        }
        html.Append("</section>");

        // 排行
        html.Append("<section><h2>跨会话发言排行</h2>");
        if (topSenders.Count == 0)
        {
            html.Append("<p class=\"sub\">无发言数据</p>");
        }
        else
        {
            foreach (var (name, count) in topSenders)
            {
                var w = Math.Max(3, (int)((double)count / maxSender * 100));
                html.Append($"<div class=\"bar-row\"><span class=\"bar-label\">{Escape(name)}</span>");
                html.Append($"<div class=\"bar-track\"><div class=\"bar\" style=\"width:{w}%\"></div></div>");
                html.Append($"<span class=\"bar-value\">{count}</span></div>");
            }
        }
        html.Append("</section>");

        // 24 小时
        html.Append("<section><h2>24 小时活跃分布</h2><div class=\"hours\">");
        for (var h = 0; h < 24; h++)
        {
            var c = hourBuckets[h];
            var hh = maxHour > 0 ? (int)Math.Round((double)c / maxHour * 100) : 0;
            html.Append($"<div class=\"hour-cell\"><div class=\"hour-bar\" style=\"height:{hh}%\" title=\"{c} 条\"></div><span>{h}时</span></div>");
        }
        html.Append("</div></section>");

        html.Append($"<footer>由 WeChatExporter 本地生成 · 数据未离开你的设备{Watermark.HtmlFooter()}</footer>");
        html.Append("<script>const DATA=").Append(json).Append(";</script>");
        html.Append("</body></html>");

        var outPath = Path.Combine(baseDir, $"年度报告_{year}.html");
        try
        {
            File.WriteAllText(outPath, html.ToString(), new UTF8Encoding(false));
            log?.Invoke($"年度报告已生成：{Path.GetFileName(outPath)}");
            return outPath;
        }
        catch (Exception ex)
        {
            log?.Invoke($"年度报告写入失败：{ex.Message}");
            return null;
        }
    }

    // MARK: - 分词（CJK bigram + 拉丁单词）

    private static List<string> Tokenize(string text)
    {
        var words = new List<string>();
        var cjk = new StringBuilder();
        var latin = new StringBuilder();

        void FlushLatin()
        {
            var w = latin.ToString().ToLowerInvariant();
            latin.Clear();
            if (w.Length >= 2 && !Stopwords.Contains(w)) words.Add(w);
        }
        void FlushCjk()
        {
            var chars = cjk.ToString();
            cjk.Clear();
            if (chars.Length == 1)
            {
                if (!Stopwords.Contains(chars)) words.Add(chars);
                return;
            }
            if (chars.Length < 2) return;
            for (var i = 0; i < chars.Length - 1; i++)
            {
                var pair = chars.Substring(i, 2);
                if (!Stopwords.Contains(pair)) words.Add(pair);
            }
        }

        foreach (var ch in text)
        {
            var v = (int)ch;
            if (v >= 0x4E00 && v <= 0x9FFF)
            {
                FlushLatin();
                cjk.Append(ch);
            }
            else if (char.IsLetterOrDigit(ch))
            {
                FlushCjk();
                latin.Append(ch);
            }
            else
            {
                FlushLatin();
                FlushCjk();
            }
        }
        FlushLatin();
        FlushCjk();
        return words;
    }

    // MARK: - 工具

    private static long NormalizeTs(long ts) => ts > 100_000_000_000L ? ts / 1000 : ts;

    private static long? GetInt(JsonNode node, params string[] keys)
    {
        if (node is not JsonObject obj) return null;
        foreach (var key in keys)
        {
            if (obj[key] is not JsonValue v) continue;
            if (v.TryGetValue<long>(out var n)) return n;
            if (v.TryGetValue<int>(out var i)) return i;
            if (v.TryGetValue<string>(out var s) && long.TryParse(s, out var p)) return p;
        }
        return null;
    }

    private static string? GetString(JsonNode node, params string[] keys)
    {
        if (node is not JsonObject obj) return null;
        foreach (var key in keys)
        {
            if (obj[key] is JsonValue v && v.TryGetValue<string>(out var s) && !string.IsNullOrEmpty(s))
                return s;
        }
        return null;
    }

    private static List<string> GetMedia(JsonNode row, JsonNode source)
    {
        foreach (var el in new[] { row, source })
        {
            if (el is JsonObject obj && obj["media_files"] is JsonArray arr)
            {
                var list = new List<string>();
                foreach (var item in arr)
                {
                    if (item is JsonValue v && v.TryGetValue<string>(out var s) && !string.IsNullOrEmpty(s))
                        list.Add(s);
                }
                if (list.Count > 0) return list;
            }
        }
        return [];
    }

    private static string Escape(string s) =>
        s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");

    private const string Styles = """
    :root { --bg: #0b1026; --card: rgba(255,255,255,0.05); --cyan: #00f5ff; --purple: #7b61ff; --text: #f0f8ff; --sub: #9aa7c7; }
    * { box-sizing: border-box; }
    body { margin: 0; padding: 32px 16px; background: radial-gradient(1200px 600px at 50% -100px, #1b2a5e 0%, var(--bg) 60%); color: var(--text); font-family: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif; }
    header, section { max-width: 920px; margin: 0 auto 20px; }
    header { text-align: center; }
    h1 { font-size: 26px; margin: 0 0 8px; }
    .sub { color: var(--sub); font-size: 13px; }
    .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; }
    .card { background: var(--card); border: 1px solid rgba(0,245,255,0.18); border-radius: 14px; padding: 16px; text-align: center; }
    .card .num { font-size: 26px; font-weight: 700; color: var(--cyan); word-break: break-all; }
    section { background: var(--card); border: 1px solid rgba(0,245,255,0.14); border-radius: 14px; padding: 20px; }
    h2 { font-size: 17px; margin: 0 0 14px; color: var(--cyan); }
    .bar-row { display: flex; align-items: center; gap: 10px; margin: 7px 0; font-size: 13px; }
    .bar-label { width: 120px; text-align: right; color: var(--text); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bar-track { flex: 1; height: 13px; background: rgba(255,255,255,0.07); border-radius: 7px; overflow: hidden; }
    .bar { height: 100%; background: linear-gradient(90deg, var(--cyan), var(--purple)); border-radius: 7px; }
    .bar-value { width: 70px; color: var(--sub); }
    .heat { display: inline-grid; grid-auto-flow: column; gap: 3px; align-items: center; }
    .heat-weekday { display: flex; flex-direction: column; gap: 3px; margin-left: 84px; }
    .heat-weekday span { height: 14px; line-height: 14px; font-size: 10px; color: var(--sub); text-align: center; }
    .heat-row { display: flex; gap: 3px; align-items: center; margin: 3px 0; }
    .heat-month { width: 76px; font-size: 11px; color: var(--sub); }
    .heat-cell { width: 16px; height: 14px; border-radius: 3px; }
    .hours { display: grid; grid-template-columns: repeat(12, 1fr); gap: 6px; }
    .hour-cell { text-align: center; font-size: 11px; color: var(--sub); }
    .hour-bar { margin: 0 auto 4px; width: 70%; min-height: 3px; height: 56px; display: flex; align-items: flex-end; background: linear-gradient(180deg, var(--cyan), var(--purple)); border-radius: 4px 4px 0 0; }
    footer { text-align: center; color: var(--sub); font-size: 12px; margin-top: 24px; max-width: 920px; margin-left: auto; margin-right: auto; }
    """;
}
