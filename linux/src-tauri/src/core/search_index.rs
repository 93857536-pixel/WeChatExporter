//! 全文搜索索引（SPEC §1）：导出根目录 `wce-search.sqlite`，FTS5 优先，缺失降级 LIKE

use crate::core::models::Message;
use crate::core::Result;
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchHit {
    pub chat: String,
    pub ts: i64,
    pub sender: String,
    pub content: String,
}

/// 扫描导出根目录下每个会话目录的 chat.json，重建 wce-search.sqlite
pub fn build_index(export_root: &Path, log: &mut dyn FnMut(String)) -> Result<()> {
    let db_path = export_root.join("wce-search.sqlite");
    let conn =
        Connection::open(&db_path).map_err(|e| crate::core::err(format!("打开索引库失败：{e}")))?;

    conn.execute_batch("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);")
        .map_err(|e| crate::core::err(format!("建 meta 表失败：{e}")))?;

    // trigram 分词器：支持中文任意子串检索（要求 SQLite ≥3.34；建表失败自动降级 LIKE）
    let fts_ok = conn
        .execute_batch(
            "CREATE VIRTUAL TABLE IF NOT EXISTS wce_fts USING fts5(chat, ts UNINDEXED, sender, content, tokenize='trigram');",
        )
        .is_ok();
    if !fts_ok {
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS wce_rows(chat TEXT, ts INTEGER, sender TEXT, content TEXT);",
        )
        .map_err(|e| crate::core::err(format!("建 wce_rows 表失败：{e}")))?;
    }

    // 清空重建
    let _ = conn.execute_batch("DELETE FROM wce_fts; DELETE FROM wce_rows;");

    let sessions = session_dirs_with_chat_json(export_root);
    let mut total = 0usize;
    for (chat, json_path) in sessions {
        let data = match std::fs::read_to_string(&json_path) {
            Ok(d) => d,
            Err(_) => continue,
        };
        let messages: Vec<Message> = match serde_json::from_str(&data) {
            Ok(m) => m,
            Err(_) => continue,
        };
        for msg in messages {
            let content = indexable_content(&msg);
            if content.is_empty() {
                continue;
            }
            let chat_clean = chat.replace('\n', " ");
            let sender_clean = msg.sender.replace('\n', " ");
            if fts_ok {
                let _ = conn.execute(
                    "INSERT INTO wce_fts(chat, ts, sender, content) VALUES (?1, ?2, ?3, ?4)",
                    rusqlite::params![chat_clean, msg.timestamp, sender_clean, content],
                );
            } else {
                let _ = conn.execute(
                    "INSERT INTO wce_rows(chat, ts, sender, content) VALUES (?1, ?2, ?3, ?4)",
                    rusqlite::params![chat_clean, msg.timestamp, sender_clean, content],
                );
            }
            total += 1;
        }
    }

    let generated_at = crate::core::util::now_local_iso();
    let _ = conn.execute(
        "INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version','1'), ('generated_at',?1), ('message_count',?2)",
        rusqlite::params![generated_at, total.to_string()],
    );
    log(format!(
        "搜索索引已生成：{total} 条消息 → wce-search.sqlite"
    ));
    Ok(())
}

/// 搜索（FTS5 MATCH 优先，降级 LIKE），按 ts 倒序取前 limit 条
pub fn search(export_root: &Path, keyword: &str, limit: usize) -> Result<Vec<SearchHit>> {
    let db_path = export_root.join("wce-search.sqlite");
    if !db_path.exists() {
        return Err(crate::core::err("未找到 wce-search.sqlite，请先导出"));
    }
    let conn = Connection::open_with_flags(&db_path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| crate::core::err(format!("打开索引库失败：{e}")))?;

    let has_fts = conn
        .prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='wce_fts'")
        .and_then(|mut s| s.exists([]))
        .unwrap_or(false);

    let mut hits = Vec::new();
    if has_fts {
        if keyword.chars().count() < 3 {
            // trigram 索引要求关键词 ≥3 字符；短词走 FTS5 shadow 表 LIKE 兜底
            // （wce_fts_content 列映射：c0=chat c1=ts c2=sender c3=content）
            let sql = "SELECT c0, c1, c2, c3 FROM wce_fts_content WHERE c3 LIKE ?1 ORDER BY c1 DESC LIMIT ?2";
            if let Ok(mut stmt) = conn.prepare(sql) {
                let pattern = format!("%{keyword}%");
                if let Ok(mut rows) = stmt.query(rusqlite::params![pattern, limit as i64]) {
                    while let Ok(Some(row)) = rows.next() {
                        hits.push(read_hit(&row));
                    }
                }
            }
        } else {
            let escaped = keyword.replace('"', "\"\"");
            let query = format!("\"{escaped}\"");
            let sql = "SELECT chat, ts, sender, content FROM wce_fts WHERE wce_fts MATCH ?1 ORDER BY ts DESC LIMIT ?2";
            if let Ok(mut stmt) = conn.prepare(sql) {
                if let Ok(mut rows) = stmt.query(rusqlite::params![query, limit as i64]) {
                    while let Ok(Some(row)) = rows.next() {
                        hits.push(read_hit(&row));
                    }
                }
            }
        }
    } else {
        let sql = "SELECT chat, ts, sender, content FROM wce_rows WHERE content LIKE ?1 ORDER BY ts DESC LIMIT ?2";
        let pattern = format!("%{keyword}%");
        if let Ok(mut stmt) = conn.prepare(sql) {
            if let Ok(mut rows) = stmt.query(rusqlite::params![pattern, limit as i64]) {
                while let Ok(Some(row)) = rows.next() {
                    hits.push(read_hit(&row));
                }
            }
        }
    }
    Ok(hits)
}

fn read_hit(row: &rusqlite::Row<'_>) -> SearchHit {
    SearchHit {
        chat: row.get::<_, String>(0).unwrap_or_default(),
        ts: row.get::<_, i64>(1).unwrap_or_default(),
        sender: row.get::<_, String>(2).unwrap_or_default(),
        content: row.get::<_, String>(3).unwrap_or_default(),
    }
}

/// 只有文本类消息入库；媒体类存占位
fn indexable_content(msg: &Message) -> String {
    if crate::core::models::is_media_type(msg.msg_type) {
        return match msg.msg_type {
            3 => "[图片]".to_string(),
            34 => "[语音]".to_string(),
            43 => "[视频]".to_string(),
            47 => "[表情]".to_string(),
            _ => String::new(),
        };
    }
    if msg.content.is_empty() {
        return String::new();
    }
    msg.content.clone()
}

/// 返回 (会话显示名, chat.json 路径) 列表
fn session_dirs_with_chat_json(export_root: &Path) -> Vec<(String, std::path::PathBuf)> {
    let mut out = Vec::new();
    let entries = match std::fs::read_dir(export_root) {
        Ok(e) => e,
        Err(_) => return out,
    };
    for e in entries.filter_map(|e| e.ok()) {
        let p = e.path();
        if p.is_dir() {
            let json = p.join("chat.json");
            if json.exists() {
                out.push((e.file_name().to_string_lossy().into_owned(), json));
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_chat(dir: &Path, name: &str, msgs: &[Message]) {
        let d = dir.join(name);
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("chat.json"), serde_json::to_string(msgs).unwrap()).unwrap();
    }

    fn msg(ts: i64, sender: &str, content: &str) -> Message {
        Message {
            time: "t".into(),
            timestamp: ts,
            sender: sender.into(),
            msg_type: 1,
            type_name: "文本".into(),
            content: content.into(),
        }
    }

    #[test]
    fn build_and_search() {
        let dir = tempfile::tempdir().unwrap();
        write_chat(
            dir.path(),
            "张三",
            &[
                msg(100, "张三", "今晚一起吃饭吗"),
                msg(200, "李四", "好的没问题"),
            ],
        );
        write_chat(dir.path(), "李四", &[msg(300, "李四", "项目文档发你了")]);
        let mut log = |s: String| eprintln!("{s}");
        build_index(dir.path(), &mut log).unwrap();

        let hits = search(dir.path(), "吃饭", 20).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].chat, "张三");
        assert!(hits[0].content.contains("吃饭"));
    }
}
