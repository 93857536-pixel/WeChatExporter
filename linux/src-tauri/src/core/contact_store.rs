//! 会话 / 联系人读取（与 macOS `ContactStore.swift` 完全同口径）

use crate::core::db;
use crate::core::models::{ContactItem, ContactKind};
use crate::core::util;
use md5::{Digest, Md5};
use std::collections::HashMap;
use std::path::Path;

/// `Msg_<md5(username)>` 表名
pub fn msg_table_for(username: &str) -> String {
    format!("Msg_{:x}", Md5::digest(username.as_bytes()))
}

/// 联系人元信息：nick / remark
#[derive(Debug, Clone, Default)]
pub struct ContactMeta {
    pub nick: String,
    pub remark: String,
}

pub type ContactMap = HashMap<String, ContactMeta>;

/// 从已解密目录加载会话列表
pub fn load_contacts(decrypted_dir: &Path) -> Result<Vec<ContactItem>, crate::core::Error> {
    let session_db = decrypted_dir.join("session").join("session.db");
    let contact_db = decrypted_dir.join("contact").join("contact.db");
    if !session_db.exists() {
        return Err(crate::core::err("会话数据库不存在"));
    }

    let existing_tables = existing_message_tables(decrypted_dir)?;
    let contacts = contact_map(&contact_db)?;

    let conn = db::open_readonly(&session_db)
        .map_err(|e| crate::core::err(format!("打开 session.db 失败：{e}")))?;

    if !db::table_exists(&conn, "SessionTable") {
        return Err(crate::core::err("session.db 缺少 SessionTable"));
    }

    let columns = db::column_names(&conn, "SessionTable");
    let summary_col = if columns.iter().any(|c| c == "summary") {
        "summary"
    } else {
        "''"
    };
    let last_ts_col = if columns.iter().any(|c| c == "last_timestamp") {
        "last_timestamp"
    } else {
        "0"
    };
    let sort_ts_col = if columns.iter().any(|c| c == "sort_timestamp") {
        "sort_timestamp"
    } else {
        last_ts_col
    };

    let sql = format!(
        "SELECT username, type, {summary_col}, {last_ts_col}, {sort_ts_col} FROM SessionTable ORDER BY {sort_ts_col} DESC"
    );
    let mut stmt = conn
        .prepare(&sql)
        .map_err(|e| crate::core::err(format!("读取会话列表失败：{e}")))?;

    let mut items: Vec<ContactItem> = Vec::new();
    let mut rows = stmt
        .query([])
        .map_err(|e| crate::core::err(format!("读取会话列表失败：{e}")))?;
    while let Some(row) = rows
        .next()
        .map_err(|e| crate::core::err(format!("读取会话列表失败：{e}")))?
    {
        let username: String = match row.get_ref(0) {
            Ok(rusqlite::types::ValueRef::Text(t)) => String::from_utf8_lossy(t).into_owned(),
            _ => continue,
        };
        if username.is_empty() {
            continue;
        }
        let kind_raw = db::coerce_int(&row, 1);
        let summary: String = match row.get_ref(2) {
            Ok(rusqlite::types::ValueRef::Text(t)) => String::from_utf8_lossy(t).into_owned(),
            _ => String::new(),
        };
        let last_ts = db::coerce_int(&row, 3);
        let sort_ts = db::coerce_int(&row, 4);

        let table = msg_table_for(&username);
        if !existing_tables.contains(&table) {
            continue;
        }

        let meta = contacts.get(&username);
        let nick = meta.map(|m| m.nick.clone()).unwrap_or_default();
        let remark = meta.map(|m| m.remark.clone()).unwrap_or_default();
        let display = if !remark.is_empty() {
            remark.clone()
        } else if !nick.is_empty() {
            nick.clone()
        } else {
            username.clone()
        };
        let ts = if sort_ts > 0 { sort_ts } else { last_ts };
        let kind = if username.ends_with("@chatroom") || kind_raw == 2 {
            ContactKind::Group
        } else if username.starts_with("gh_") {
            ContactKind::Official
        } else {
            ContactKind::Friend
        };

        items.push(ContactItem {
            id: username,
            display_name: display,
            nick_name: nick,
            remark,
            kind,
            last_time: util::format_time(ts),
            last_timestamp: ts,
            summary: summary.replace('\n', " "),
        });
    }
    items.sort_by(|a, b| b.last_timestamp.cmp(&a.last_timestamp));
    Ok(items)
}

/// 扫描 message/*.db 中所有 `Msg_%` 表名集合
pub fn existing_message_tables(
    decrypted_dir: &Path,
) -> Result<std::collections::HashSet<String>, crate::core::Error> {
    let mut tables = std::collections::HashSet::new();
    let message_dir = decrypted_dir.join("message");
    let entries = match std::fs::read_dir(&message_dir) {
        Ok(e) => e,
        Err(_) => return Ok(tables),
    };
    let mut files: Vec<_> = entries
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
    files.sort();
    for file in files {
        if let Ok(conn) = db::open_readonly(&file) {
            for name in db::table_names_like(&conn, "Msg_") {
                tables.insert(name);
            }
        }
    }
    Ok(tables)
}

/// 读取 contact.db 的 `contact` 表 → username -> (nick, remark)
pub fn contact_map(contact_db: &Path) -> Result<ContactMap, crate::core::Error> {
    let mut map = ContactMap::new();
    if !contact_db.exists() {
        return Ok(map);
    }
    let conn = match db::open_readonly(contact_db) {
        Ok(c) => c,
        Err(_) => return Ok(map),
    };
    if !db::table_exists(&conn, "contact") {
        return Ok(map);
    }

    let columns = db::column_names(&conn, "contact");
    let nick_col = if columns.iter().any(|c| c == "nick_name") {
        "nick_name"
    } else if columns.iter().any(|c| c == "nickName") {
        "nickName"
    } else {
        "''"
    };
    let remark_col = if columns.iter().any(|c| c == "remark") {
        "remark"
    } else {
        "''"
    };

    let sql = format!("SELECT username, {nick_col}, {remark_col} FROM contact");
    let mut stmt = match conn.prepare(&sql) {
        Ok(s) => s,
        Err(_) => return Ok(map),
    };
    let mut rows = match stmt.query([]) {
        Ok(r) => r,
        Err(_) => return Ok(map),
    };
    while let Ok(Some(row)) = rows.next() {
        let username: String = match row.get_ref(0) {
            Ok(rusqlite::types::ValueRef::Text(t)) => String::from_utf8_lossy(t).into_owned(),
            _ => continue,
        };
        let nick: String = match row.get_ref(1) {
            Ok(rusqlite::types::ValueRef::Text(t)) => String::from_utf8_lossy(t).into_owned(),
            _ => String::new(),
        };
        let remark: String = match row.get_ref(2) {
            Ok(rusqlite::types::ValueRef::Text(t)) => String::from_utf8_lossy(t).into_owned(),
            _ => String::new(),
        };
        map.insert(username, ContactMeta { nick, remark });
    }
    Ok(map)
}

/// 展示名：备注 > 昵称 > username
pub fn display_name(username: &str, map: &ContactMap) -> String {
    if let Some(meta) = map.get(username) {
        if !meta.remark.is_empty() {
            return meta.remark.clone();
        }
        if !meta.nick.is_empty() {
            return meta.nick.clone();
        }
    }
    username.to_string()
}
