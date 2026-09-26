using System.IO;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace WeChatExporter.Services;

/// <summary>
/// 全文搜索索引（SPEC §1）：导出根目录生成 wce-search.sqlite。
/// 优先 FTS5 虚拟表 wce_fts；不支持时降级普通表 wce_rows + LIKE 查询。
/// 每行 = 一条消息：chat(会话显示名) / ts(Unix秒) / sender / content。
/// 与 macOS Services/SearchIndexService.swift 对称实现（双端产物格式一致）。
/// </summary>
public static class SearchIndexService
{
    public const string FileName = "wce-search.sqlite";

    public sealed record Hit(string Chat, long Ts, string Sender, string Content)
    {
        /// <summary>内容摘要（±40 字符窗口，与 macOS 同口径）。</summary>
        public string Snippet
        {
            get
            {
                const int limit = 40;
                if (Content.Length <= limit) return Content;
                var start = Math.Min(limit, Content.Length / 2);
                var len = Math.Min(limit * 2, Content.Length - start);
                return Content.Substring(start, len);
            }
        }

        /// <summary>命中时间（Asia/Shanghai，展示用）。</summary>
        public string TimeText
        {
            get
            {
                if (Ts <= 0) return "-";
                var utc = DateTimeOffset.FromUnixTimeSeconds(Ts).UtcDateTime;
                var sh = TimeZoneInfo.FindSystemTimeZoneById("China Standard Time");
                return TimeZoneInfo.ConvertTimeFromUtc(utc, sh).ToString("yyyy-MM-dd HH:mm");
            }
        }
    }

    // MARK: - 构建

    /// <summary>扫描 base 下所有 chat.json，重建索引。返回入库行数。</summary>
    public static int Build(string baseDir, Action<string>? log)
    {
        var indexPath = Path.Combine(baseDir, FileName);
        try { if (File.Exists(indexPath)) File.Delete(indexPath); } catch { /* ignore */ }

        var fts5OK = false;
        var total = 0;

        var connStr = new SqliteConnectionStringBuilder { DataSource = indexPath, Mode = SqliteOpenMode.ReadWriteCreate }.ToString();
        using (var db = new SqliteConnection(connStr))
        {
            db.Open();
            fts5OK = TryCreateFts5(db);
            if (fts5OK)
            {
                Exec(db, "CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)");
                Exec(db, "CREATE TABLE IF NOT EXISTS chat_sessions(chat TEXT PRIMARY KEY)");
            }
            else
            {
                Exec(db, "CREATE TABLE IF NOT EXISTS wce_rows(chat TEXT, ts INTEGER, sender TEXT, content TEXT)");
                Exec(db, "CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)");
                log?.Invoke("FTS5 不可用，已降级为 LIKE 查询模式");
            }
            SetMeta(db, "schema_version", fts5OK ? "fts5" : "like");

            var files = FindChatJsons(baseDir);
            files.Sort(StringComparer.OrdinalIgnoreCase);
            var baseFull = Path.GetFullPath(baseDir).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

            using var insert = fts5OK
                ? db.CreateCommand()
                : db.CreateCommand();
            insert.CommandText = fts5OK
                ? "INSERT INTO wce_fts VALUES($c,$t,$s,$x)"
                : "INSERT INTO wce_rows VALUES($c,$t,$s,$x)";
            var pC = insert.CreateParameter(); insert.Parameters.Add(pC);
            var pT = insert.CreateParameter(); insert.Parameters.Add(pT);
            var pS = insert.CreateParameter(); insert.Parameters.Add(pS);
            var pX = insert.CreateParameter(); insert.Parameters.Add(pX);

            foreach (var f in files)
            {
                var fFull = Path.GetFullPath(f);
                var rel = fFull.Length > baseFull.Length && fFull.StartsWith(baseFull, StringComparison.OrdinalIgnoreCase)
                    ? fFull[(baseFull.Length + 1)..]
                    : Path.GetFileName(f);
                var first = rel.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).FirstOrDefault() ?? "";
                var rows = LoadRows(f);
                if (rows.Count == 0) continue;
                var session = string.IsNullOrWhiteSpace(first) ? "未命名" : first;

                using var tx = db.BeginTransaction();
                foreach (var r in rows)
                {
                    pC.Value = session;
                    pT.Value = r.Ts;
                    pS.Value = r.Sender;
                    pX.Value = r.Content;
                    insert.Transaction = tx;
                    insert.ExecuteNonQuery();
                    total++;
                }
                if (fts5OK)
                {
                    using var cmd = db.CreateCommand();
                    cmd.CommandText = "INSERT OR IGNORE INTO chat_sessions(chat) VALUES($c)";
                    cmd.Parameters.AddWithValue("$c", session);
                    cmd.Transaction = tx;
                    cmd.ExecuteNonQuery();
                }
                tx.Commit();
            }

            SetMeta(db, "generated_at", DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
            SetMeta(db, "message_count", total.ToString());
        }

        if (total > 0)
            log?.Invoke($"搜索索引已生成：{FileName}（{total} 条消息）");
        else
            log?.Invoke($"搜索索引已生成：{FileName}（无消息数据）");
        return total;
    }

    // MARK: - 查询

    /// <summary>打开索引（只读）；不存在或打开失败返回 null。</summary>
    public static SqliteConnection? Open(string indexAt)
    {
        if (!File.Exists(indexAt)) return null;
        try
        {
            var connStr = new SqliteConnectionStringBuilder
            {
                DataSource = indexAt,
                Mode = SqliteOpenMode.ReadOnly,
                Pooling = false,
            }.ToString();
            var db = new SqliteConnection(connStr);
            db.Open();
            return db;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>关键词搜索（不区分大小写；FTS5 短语匹配，降级 LIKE），按时间倒序取 limit 条。</summary>
    public static List<Hit> Query(SqliteConnection db, string keyword, int limit = 200)
    {
        var kw = keyword.Trim();
        if (kw.Length == 0) return [];
        var useFts = TableExists(db, "wce_fts");

        var hits = new List<Hit>();
        using var cmd = db.CreateCommand();
        if (useFts)
        {
            // FTS5 短语：整体加双引号，内部双引号翻倍
            var phrase = "\"" + kw.Replace("\"", "\"\"") + "\"";
            cmd.CommandText = "SELECT chat, ts, sender, content FROM wce_fts WHERE wce_fts MATCH $p ORDER BY ts DESC LIMIT $n";
            cmd.Parameters.AddWithValue("$p", phrase);
            cmd.Parameters.AddWithValue("$n", limit);
        }
        else
        {
            var pattern = "%" + kw + "%";
            cmd.CommandText = "SELECT chat, ts, sender, content FROM wce_rows WHERE lower(content) LIKE lower($p) OR lower(sender) LIKE lower($p) ORDER BY ts DESC LIMIT $n";
            cmd.Parameters.AddWithValue("$p", pattern);
            cmd.Parameters.AddWithValue("$n", limit);
        }

        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            hits.Add(new Hit(
                reader.IsDBNull(0) ? "" : reader.GetString(0),
                reader.IsDBNull(1) ? 0 : reader.GetInt64(1),
                reader.IsDBNull(2) ? "" : reader.GetString(2),
                reader.IsDBNull(3) ? "" : reader.GetString(3)));
        }
        return hits;
    }

    // MARK: - 数据装载（与 ChatStatsReport 解析口径一致）

    private sealed record Row(long Ts, string Sender, string Content);

    private static List<string> FindChatJsons(string baseDir)
    {
        if (!Directory.Exists(baseDir)) return [];
        try
        {
            return Directory.EnumerateFiles(baseDir, "chat.json", SearchOption.AllDirectories).ToList();
        }
        catch
        {
            return [];
        }
    }

    private static List<Row> LoadRows(string jsonPath)
    {
        var rows = new List<Row>();
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(jsonPath));
            List<JsonElement> arr;
            if (doc.RootElement.ValueKind == JsonValueKind.Array)
            {
                arr = doc.RootElement.EnumerateArray().ToList();
            }
            else if (doc.RootElement.ValueKind == JsonValueKind.Object)
            {
                arr = [];
                foreach (var key in new[] { "items", "messages", "results" })
                {
                    if (doc.RootElement.TryGetProperty(key, out var a) && a.ValueKind == JsonValueKind.Array)
                    {
                        arr = a.EnumerateArray().ToList();
                        break;
                    }
                }
            }
            else
            {
                return rows;
            }

            foreach (var r in arr)
            {
                var source = r.ValueKind == JsonValueKind.Object && r.TryGetProperty("message", out var m) ? m : r;
                var ts = GetInt(source, "create_time", "timestamp") ?? GetInt(r, "create_time", "timestamp") ?? 0;
                var sender = GetString(r, "sender_display_name", "sender", "from", "display_name")
                    ?? GetString(source, "sender_display_name", "sender") ?? "未知";
                var type = GetInt(source, "local_type", "type") ?? 0;
                var content = GetString(r, "snippet", "content", "text")
                    ?? GetString(source, "content", "text") ?? "";

                // 媒体类消息用占位符（与 ChatExporter 同口径）
                string display;
                if ((type is 3 or 34 or 43 or 47) && (content.Length == 0 || content.StartsWith('[')))
                {
                    display = type switch
                    {
                        3 => "[图片]",
                        34 => "[语音]",
                        43 => "[视频]",
                        47 => "[表情]",
                        _ => "[媒体]",
                    };
                }
                else if (type != 1 && content.Length == 0)
                {
                    display = "[非文本]";
                }
                else
                {
                    display = content;
                }
                rows.Add(new Row(ts, sender, display));
            }
        }
        catch { /* 解析失败按空处理 */ }
        return rows;
    }

    // MARK: - 小工具

    private static long? GetInt(JsonElement el, params string[] keys)
    {
        if (el.ValueKind != JsonValueKind.Object) return null;
        foreach (var key in keys)
        {
            if (!el.TryGetProperty(key, out var v)) continue;
            if (v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out var n)) return n;
            if (v.ValueKind == JsonValueKind.String && long.TryParse(v.GetString(), out var s)) return s;
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

    private static bool TryCreateFts5(SqliteConnection db)
    {
        try
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = "CREATE VIRTUAL TABLE wce_fts USING fts5(chat TEXT, ts UNINDEXED, sender TEXT, content TEXT)";
            cmd.ExecuteNonQuery();
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static void Exec(SqliteConnection db, string sql)
    {
        try
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = sql;
            cmd.ExecuteNonQuery();
        }
        catch { /* ignore */ }
    }

    private static void SetMeta(SqliteConnection db, string key, string value)
    {
        try
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = "INSERT OR REPLACE INTO meta(key, value) VALUES($k, $v)";
            cmd.Parameters.AddWithValue("$k", key);
            cmd.Parameters.AddWithValue("$v", value);
            cmd.ExecuteNonQuery();
        }
        catch { /* ignore */ }
    }

    private static bool TableExists(SqliteConnection db, string name)
    {
        try
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = "SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name=$n LIMIT 1";
            cmd.Parameters.AddWithValue("$n", name);
            using var reader = cmd.ExecuteReader();
            return reader.Read();
        }
        catch
        {
            return false;
        }
    }
}
