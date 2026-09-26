//! 消息导出（与 macOS `ChatExporter.swift` 完全同口径：txt / json / csv）

use crate::core::contact_store::{self, ContactMap};
use crate::core::db;
use crate::core::models::{self, ContactItem, Message};
use crate::core::{util, Result};
use std::path::Path;

/// 导出单个会话的聊天记录到 output_dir（写入 chat.txt / chat.json / chat.csv），返回消息数
pub fn export(contact: &ContactItem, decrypted_dir: &Path, output_dir: &Path) -> Result<i64> {
    let table = contact_store::msg_table_for(&contact.id);
    let contact_db = decrypted_dir.join("contact").join("contact.db");
    let contact_map = contact_store::contact_map(&contact_db)?;
    let message_dir = decrypted_dir.join("message");

    let mut files: Vec<std::path::PathBuf> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&message_dir) {
        files = entries
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| {
                p.extension().map(|e| e == "db").unwrap_or(false)
                    && !p
                        .file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .contains("fts")
            })
            .collect();
    }
    files.sort();

    let mut messages: Vec<Message> = Vec::new();
    for file in &files {
        messages.extend(load_messages(file, &table, &contact_map)?);
    }
    messages.sort_by_key(|m| m.timestamp);
    if messages.is_empty() {
        return Err(crate::core::err(format!(
            "未找到与 {} 的聊天记录",
            contact.display_name
        )));
    }

    std::fs::create_dir_all(output_dir)
        .map_err(|e| crate::core::err(format!("创建输出目录失败：{e}")))?;

    write_artifacts(contact, &messages, output_dir)?;
    Ok(messages.len() as i64)
}

/// 把消息写入 txt / json / csv 三件套（导出与过滤重写共用）
pub fn write_artifacts(
    contact: &ContactItem,
    messages: &[Message],
    output_dir: &Path,
) -> Result<()> {
    std::fs::create_dir_all(output_dir)
        .map_err(|e| crate::core::err(format!("创建输出目录失败：{e}")))?;

    // chat.txt
    let mut txt = format!(
        "微信聊天记录: {} ({})\n总消息数: {}\n时间范围: {} ~ {}\n{}\n\n",
        contact.display_name,
        contact.id,
        messages.len(),
        messages.first().map(|m| m.time.as_str()).unwrap_or(""),
        messages.last().map(|m| m.time.as_str()).unwrap_or(""),
        "=".repeat(60)
    );
    for msg in messages {
        txt.push_str(&format!(
            "[{}] {}: {}\n",
            msg.time,
            msg.sender,
            display_content(msg)
        ));
    }
    std::fs::write(output_dir.join("chat.txt"), txt)
        .map_err(|e| crate::core::err(format!("写 chat.txt 失败：{e}")))?;

    // chat.json
    let json = serde_json::to_string_pretty(messages)
        .map_err(|e| crate::core::err(format!("序列化 chat.json 失败：{e}")))?;
    std::fs::write(output_dir.join("chat.json"), json)
        .map_err(|e| crate::core::err(format!("写 chat.json 失败：{e}")))?;

    // chat.csv（带 BOM，引号转义）
    let mut csv = String::from("\u{FEFF}时间,发送者,类型,内容\n");
    for msg in messages {
        let content = display_content(msg).replace('"', "\"\"");
        csv.push_str(&format!(
            "\"{}\",\"{}\",\"{}\",\"{}\"\n",
            msg.time, msg.sender, msg.type_name, content
        ));
    }
    std::fs::write(output_dir.join("chat.csv"), csv)
        .map_err(|e| crate::core::err(format!("写 chat.csv 失败：{e}")))?;

    Ok(())
}

fn load_messages(db_url: &Path, table: &str, contact_map: &ContactMap) -> Result<Vec<Message>> {
    let conn = match db::open_readonly(db_url) {
        Ok(c) => c,
        Err(_) => return Ok(Vec::new()),
    };

    if !db::table_exists(&conn, table) {
        return Ok(Vec::new());
    }

    // Name2Id: rowid -> user_name
    let mut name_map: std::collections::HashMap<i64, String> = std::collections::HashMap::new();
    if let Ok(mut stmt) = conn.prepare("SELECT rowid, user_name FROM Name2Id") {
        let mut rows = stmt.query([]).unwrap_or_else(|_| panic!("query Name2Id"));
        while let Ok(Some(row)) = rows.next() {
            let rowid = db::coerce_int(&row, 0);
            let name: String = match row.get_ref(1) {
                Ok(rusqlite::types::ValueRef::Text(t)) => String::from_utf8_lossy(t).into_owned(),
                _ => String::new(),
            };
            name_map.insert(rowid, name);
        }
    }

    let columns = db::column_names(&conn, table);
    let content_col = if columns.iter().any(|c| c == "message_content") {
        "message_content"
    } else if columns.iter().any(|c| c == "compress_content") {
        "compress_content"
    } else {
        "''"
    };

    let sql = format!(
        "SELECT local_type, create_time, real_sender_id, {content_col} FROM \"{}\" ORDER BY create_time ASC",
        table.replace('"', "\"\"")
    );
    let mut stmt = conn
        .prepare(&sql)
        .map_err(|e| crate::core::err(format!("读取消息失败 ({table})：{e}")))?;

    let mut result: Vec<Message> = Vec::new();
    let mut rows = stmt
        .query([])
        .map_err(|e| crate::core::err(format!("读取消息失败 ({table})：{e}")))?;
    while let Ok(Some(row)) = rows.next() {
        let msg_type = db::coerce_int(&row, 0) as i32;
        let ts = db::coerce_int(&row, 1);
        let sender_id = db::coerce_int(&row, 2);
        let content = db::decode_value(&row, 3);

        let sender_wxid = name_map.get(&sender_id).cloned().unwrap_or_default();
        let sender = if models::is_system_type(msg_type) {
            "系统".to_string()
        } else {
            contact_store::display_name(&sender_wxid, contact_map)
        };

        result.push(Message {
            time: util::format_time(ts),
            timestamp: ts,
            sender,
            msg_type,
            type_name: models::msg_type_name(msg_type),
            content,
        });
    }
    Ok(result)
}

fn display_content(msg: &Message) -> String {
    if models::is_media_type(msg.msg_type) {
        return format!("[{}]", msg.type_name);
    }
    if msg.msg_type != 1 && msg.content.is_empty() {
        return format!("[{}]", msg.type_name);
    }
    msg.content.clone()
}
