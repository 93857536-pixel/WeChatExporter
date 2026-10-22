using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace WeChatExporter.Services;

/// <summary>
/// 日历提取（SPEC §6）：从聊天消息里启发式识别时间承诺/约定，
/// 生成 日历事件.json + 日历事件.ics（TZID=Asia/Shanghai，VEVENT 默认 60 分钟）。
/// 与 macOS Services/CalendarExtractService.swift 对称实现。
/// </summary>
public static class CalendarExtractService
{
    public const string JsonName = "日历事件.json";
    public const string IcsName = "日历事件.ics";

    private static readonly TimeZoneInfo Shanghai = TimeZoneInfo.FindSystemTimeZoneById("China Standard Time");

    public sealed record Event(string Session, long MessageTs, string Summary, string Start, string End, string Raw);

    private sealed record ParsedDay(int Year, int Month, int Day, int Hour, int Minute, bool IsRelative, int OffsetDay);

    /// <summary>提取日历事件，返回事件条数。</summary>
    public static int Extract(string baseDir, Action<string>? log)
    {
        var events = new List<Event>();
        var jsonFiles = new List<string>();
        if (Directory.Exists(baseDir))
        {
            try { jsonFiles = Directory.EnumerateFiles(baseDir, "chat.json", SearchOption.AllDirectories).ToList(); }
            catch { /* ignore */ }
        }

        foreach (var jsonPath in jsonFiles)
        {
            var sessionName = Path.GetFileName(Path.GetDirectoryName(jsonPath)) ?? "";
            List<JsonNode> rows;
            try
            {
                var root = JsonNode.Parse(File.ReadAllText(jsonPath));
                if (root is JsonArray arr) rows = arr.Select(n => n!).ToList();
                else if (root is JsonObject obj)
                {
                    rows = [];
                    foreach (var key in new[] { "items", "messages", "results" })
                    {
                        if (obj[key] is JsonArray a) { rows = a.Select(n => n!).ToList(); break; }
                    }
                }
                else rows = [];
            }
            catch { continue; }

            foreach (var row in rows)
            {
                try
                {
                    var source = row is JsonObject o && o["message"] is JsonObject msg ? msg : row;
                    var ts = GetInt(source, "create_time", "timestamp") ?? GetInt(row, "create_time", "timestamp");
                    if (ts is not { } rawTs || rawTs <= 0) continue;
                    var msgTs = NormalizeTs(rawTs);
                    var text = GetString(row, "snippet", "content", "text")
                        ?? GetString(source, "content", "text") ?? "";
                    if (ParseDay(text, msgTs) is not { } day) continue;

                    var msgDate = ShanghaiLocal(msgTs);
                    DateTime? date;
                    if (day.IsRelative)
                    {
                        var baseDate = msgDate.AddDays(day.OffsetDay);
                        date = ValidDay(baseDate.Year, baseDate.Month, baseDate.Day)
                            ? new DateTime(baseDate.Year, baseDate.Month, baseDate.Day, day.Hour, day.Minute, 0)
                            : (DateTime?)null;
                    }
                    else
                    {
                        // 2026-02-30 这类非法日：ValidDay 拦截，不再 new DateTime 抛异常
                        if (!ValidDay(day.Year, day.Month, day.Day)) continue;
                        date = new DateTime(day.Year, day.Month, day.Day, day.Hour, day.Minute, 0);
                        if (date < msgDate)
                        {
                            // 次年同位置仍须为合法日（如 2023-02-29 的次年 2024 合法、2025 不合法）
                            if (!ValidDay(day.Year + 1, day.Month, day.Day)) continue;
                            date = new DateTime(day.Year + 1, day.Month, day.Day, day.Hour, day.Minute, 0);
                        }
                    }
                    if (date is not { } d) continue;

                    var start = d.ToString("yyyy-MM-dd HH:mm");
                    var end = d.AddMinutes(60).ToString("yyyy-MM-dd HH:mm");
                    var summary = Substring(text, 60).Replace("\n", " ");
                    events.Add(new Event(sessionName, msgTs, summary, start, end, Substring(text, 120)));
                }
                catch { /* 单行解析失败不影响其余行 */ }
            }
        }

        var jsonPathOut = Path.Combine(baseDir, JsonName);
        try
        {
            File.WriteAllText(jsonPathOut,
                JsonSerializer.Serialize(events, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true }),
                new UTF8Encoding(false));
        }
        catch { /* ignore */ }
        try { WriteIcs(events, Path.Combine(baseDir, IcsName)); } catch { /* ignore */ }

        log?.Invoke($"日历事件已生成：{IcsName} + {JsonName}（{events.Count} 条）");
        return events.Count;
    }

    // MARK: - 解析（SPEC §6 规则；全部本地计算）

    private static ParsedDay? ParseDay(string text, long msgTs)
    {
        var msgDate = ShanghaiLocal(msgTs);
        var msgYear = msgDate.Year;
        var msgWeekday = (int)msgDate.DayOfWeek; // 0=周日 … 6=周六（与 Swift weekday-1 对齐）

        var hour = 9;
        var minute = 0;
        var timeHit = false;

        // 1) 相对天词（按优先级命中即停）
        int? offset = null;
        foreach (var (word, off) in new[] { ("大后天", 3), ("后天", 2), ("明天", 1), ("今晚", 0), ("今天", 0) })
        {
            if (!text.Contains(word, StringComparison.Ordinal)) continue;
            offset = off;
            if (word == "今晚") { hour = 20; timeHit = true; }
            break;
        }

        // 2) 周X / 星期X：最近的未来那一天
        if (offset is null)
        {
            var map = new[] { ("周一", 1), ("周二", 2), ("周三", 3), ("周四", 4), ("周五", 5), ("周六", 6), ("周日", 0), ("周天", 0) };
            foreach (var (word, target) in map)
            {
                var suffix = word[^1].ToString();
                if (text.Contains(word, StringComparison.Ordinal) || text.Contains("星期" + suffix, StringComparison.Ordinal))
                {
                    var delta = target - msgWeekday;
                    if (delta <= 0) delta += 7;
                    offset = delta;
                    break;
                }
            }
        }

        // 3) 绝对日期 M月D日
        int? absY = null;
        int? absM = null;
        int? absD = null;
        var reMd = System.Text.RegularExpressions.Regex.Match(text, @"(\d{1,2})月(\d{1,2})日");
        if (reMd.Success)
        {
            var mo = int.Parse(reMd.Groups[1].Value);
            var dy = int.Parse(reMd.Groups[2].Value);
            // 与 macOS Foundation Calendar 同口径：构造 DateTime 前先校验该月实际天数，
            // 非法日（如 4 月 31 / 2 月 30）直接丢弃，避免 new DateTime 抛异常拖垮整条管线
            if (mo is >= 1 and <= 12 && dy is >= 1 and <= 31 && ValidDay(msgYear, mo, dy)) { absM = mo; absD = dy; }
        }

        // 4) 绝对日期 YYYY-MM-DD / YYYY/MM/DD
        if (absM is null)
        {
            var reFull = System.Text.RegularExpressions.Regex.Match(text, @"(\d{4})[-/](\d{1,2})[-/](\d{1,2})");
            if (reFull.Success)
            {
                var y = int.Parse(reFull.Groups[1].Value);
                var mo = int.Parse(reFull.Groups[2].Value);
                var dy = int.Parse(reFull.Groups[3].Value);
                if (y > 2000 && mo is >= 1 and <= 12 && dy is >= 1 and <= 31 && ValidDay(y, mo, dy)) { absY = y; absM = mo; absD = dy; }
            }
        }

        // 5) 时刻词：上午/早上/中午/下午/晚上 + N点(半)
        foreach (var (word, isPm) in new[] { ("上午", false), ("早上", false), ("中午", false), ("下午", true), ("晚上", true) })
        {
            var idx = text.IndexOf(word, StringComparison.Ordinal);
            if (idx < 0) continue;
            var tail = text[(idx + word.Length)..];
            if (FirstHour(tail, isPm) is { } hm)
            {
                hour = hm.Hour;
                minute = hm.Minute;
                timeHit = true;
            }
            break;
        }

        // 6) 裸 N点 / N点半
        if (!timeHit)
        {
            if (FirstHour(text, false) is { } hm)
            {
                hour = hm.Hour;
                minute = hm.Minute;
                timeHit = true;
            }
        }

        // 必须至少命中一个天词/日期/时刻词
        if (offset is null && absM is null && !timeHit) return null;

        if (absM is not null)
        {
            return new ParsedDay(absY ?? msgYear, absM.Value, absD ?? 1, hour, minute, false, 0);
        }
        return new ParsedDay(0, 0, 0, hour, minute, true, offset ?? 0);
    }

    private sealed record HourMinute(int Hour, int Minute);

    /// <summary>取文本中第一个 N点(半)；pm=true 时 N&lt;12 加 12。</summary>
    private static HourMinute? FirstHour(string s, bool pm)
    {
        var re = System.Text.RegularExpressions.Regex.Match(s, @"(\d{1,2})点半?");
        if (!re.Success) return null;
        var raw = int.Parse(re.Groups[1].Value);
        if (raw is < 0 or > 23) return null;
        var h = raw;
        if (pm && h < 12) h += 12;
        if (h is < 0 or > 23) return null;
        var minute = re.Value.Contains('半') ? 30 : 0;
        return new HourMinute(h, minute);
    }

    // MARK: - ICS

    private static void WriteIcs(List<Event> events, string path)
    {
        var stamp = DateTime.UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'");
        var sb = new StringBuilder();
        sb.Append("BEGIN:VCALENDAR\r\n");
        sb.Append("VERSION:2.0\r\n");
        sb.Append("PRODID:-//WeChatExporter//CN\r\n");
        sb.Append("CALSCALE:GREGORIAN\r\n");
        sb.Append("X-WR-CALNAME:微信聊天记录导出·日历事件\r\n");
        sb.Append("X-WR-TIMEZONE:Asia/Shanghai\r\n");
        sb.Append("BEGIN:VTIMEZONE\r\nTZID:Asia/Shanghai\r\n");
        sb.Append("BEGIN:STANDARD\r\nDTSTART:19700101T000000\r\nTZOFFSETFROM:+0800\r\nTZOFFSETTO:+0800\r\nTZNAME:CST\r\nEND:STANDARD\r\n");
        sb.Append("END:VTIMEZONE\r\n");
        foreach (var e in events)
        {
            if (!TryParseShanghai(e.Start, out var s) || !TryParseShanghai(e.End, out var en)) continue;
            var uid = Fnv1a($"{e.Session}|{e.MessageTs}|{e.Start}");
            sb.Append("BEGIN:VEVENT\r\n");
            sb.Append($"UID:{uid}@wce\r\n");
            sb.Append($"DTSTAMP:{stamp}\r\n");
            sb.Append($"DTSTART;TZID=Asia/Shanghai:{s:yyyyMMdd'T'HHmmss}\r\n");
            sb.Append($"DTEND;TZID=Asia/Shanghai:{en:yyyyMMdd'T'HHmmss}\r\n");
            sb.Append(FoldIcsLine($"SUMMARY:{IcsEscape(e.Session)}｜{IcsEscape(e.Summary)}") + "\r\n");
            sb.Append(FoldIcsLine($"DESCRIPTION:原文：{IcsEscape(e.Raw)}") + "\r\n");
            sb.Append("END:VEVENT\r\n");
        }
        sb.Append("END:VCALENDAR\r\n");
        File.WriteAllText(path, sb.ToString(), new UTF8Encoding(false));
    }

    /// <summary>ICS 值转义（RFC 5545 §3.3.11）：反斜杠 / 分号 / 逗号 / 换行。</summary>
    private static string IcsEscape(string s)
    {
        if (string.IsNullOrEmpty(s)) return s ?? "";
        var sb = new StringBuilder(s.Length);
        foreach (var c in s)
        {
            switch (c)
            {
                case '\\': sb.Append("\\\\"); break;
                case ';': sb.Append("\\;"); break;
                case ',': sb.Append("\\,"); break;
                case '\r': break; // 去掉 CR，统一用 \n
                case '\n': sb.Append("\\n"); break;
                default: sb.Append(c); break;
            }
        }
        return sb.ToString();
    }

    /// <summary>ICS 行折叠（RFC 5545 §3.1）：行内插 CRLF + 空格续行，UTF-8 计 75 octet。</summary>
    private static string FoldIcsLine(string line)
    {
        if (string.IsNullOrEmpty(line)) return line ?? "";
        var bytes = Encoding.UTF8.GetBytes(line);
        if (bytes.Length <= 75) return line;
        // 每行最多 75 octet，续行行首一个空格（占 1 octet）
        var sb = new StringBuilder();
        var first = true;
        var offset = 0;
        while (offset < bytes.Length)
        {
            var budget = first ? 75 : 74; // 续行含 1 个前导空格
            int end = offset + budget;
            // 不切在 UTF-8 多字节字符中间（回退到续行字节边界 0x80-0xBF 之前）
            while (end < bytes.Length && end > offset && (bytes[end] & 0xC0) == 0x80) end--;
            var chunk = Encoding.UTF8.GetString(bytes, offset, end - offset);
            if (first)
            {
                sb.Append(chunk);
                first = false;
            }
            else
            {
                sb.Append(" ");
                sb.Append(chunk);
            }
            if (end < bytes.Length) sb.Append("\r\n");
            offset = end;
        }
        return sb.ToString();
    }

    private static bool TryParseShanghai(string s, out DateTime dt)
    {
        dt = default;
        if (!DateTime.TryParseExact(s, "yyyy-MM-dd HH:mm", System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.None, out var parsed)) return false;
        dt = parsed;
        return true;
    }

    /// <summary>确定性 FNV-1a 64 位（ICS 的 UID 只需稳定，无需加密强度；与 macOS 同算法）。</summary>
    private static string Fnv1a(string s)
    {
        ulong hash = 0xcbf29ce484222325UL;
        foreach (var b in Encoding.UTF8.GetBytes(s))
        {
            hash ^= b;
            hash *= 0x100000001b3UL; // 环绕乘法（unchecked）
        }
        return hash.ToString("x");
    }

    // MARK: - 工具

    private static DateTime ShanghaiLocal(long seconds)
        => TimeZoneInfo.ConvertTimeFromUtc(DateTimeOffset.FromUnixTimeSeconds(seconds).UtcDateTime, Shanghai);

    private static long NormalizeTs(long ts) => ts > 100_000_000_000L ? ts / 1000 : ts;

    /// <summary>指定年某月是否含 D 号（闰年感知；与 macOS Foundation Calendar 的 date(from:) 合法口径对齐）。</summary>
    private static bool ValidDay(int year, int month, int day)
        => year is > 0 && month is >= 1 and <= 12 && day is >= 1 and <= 31 && DateTime.DaysInMonth(year, month) >= day;

    private static string Substring(string s, int max)
        => s.Length <= max ? s : s[..max];

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
}
