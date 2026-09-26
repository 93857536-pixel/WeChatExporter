//! SQLite 访问（rusqlite bundled：跨平台零系统依赖）

use rusqlite::{Connection, OpenFlags};

/// 只读打开数据库
pub fn open_readonly(path: &std::path::Path) -> rusqlite::Result<Connection> {
    Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
}

/// 表是否存在
pub fn table_exists(conn: &Connection, name: &str) -> bool {
    conn.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1")
        .and_then(|mut stmt| stmt.exists([name]))
        .unwrap_or(false)
}

/// 返回表的所有列名（PRAGMA table_info，第二列为列名）
pub fn column_names(conn: &Connection, table: &str) -> Vec<String> {
    let sql = format!("PRAGMA table_info(\"{}\")", table.replace('"', "\"\""));
    let mut stmt = match conn.prepare(&sql) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    let mut cols = Vec::new();
    let mut rows = match stmt.query([]) {
        Ok(r) => r,
        Err(_) => return Vec::new(),
    };
    while let Ok(Some(row)) = rows.next() {
        if let Ok(name) = row.get::<_, String>(1) {
            cols.push(name);
        }
    }
    cols
}

/// 返回所有匹配前缀的表名（如 `Msg_%`）
pub fn table_names_like(conn: &Connection, prefix: &str) -> Vec<String> {
    let mut stmt =
        match conn.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE ?1") {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
    let pattern = format!("{prefix}%");
    let mut names = Vec::new();
    let mut rows = match stmt.query([&pattern]) {
        Ok(r) => r,
        Err(_) => return Vec::new(),
    };
    while let Ok(Some(row)) = rows.next() {
        if let Ok(name) = row.get::<_, String>(0) {
            names.push(name);
        }
    }
    names
}

/// 读取单个 BLOB/文本列，尽力解码为 UTF-8 字符串（与 macOS `decodeContent` 同口径）
pub fn decode_content(conn: &Connection, table: &str, content_col: &str, rowid: i64) -> String {
    if content_col.is_empty() {
        return String::new();
    }
    let sql = format!(
        "SELECT \"{}\" FROM \"{}\" WHERE rowid = ?1",
        content_col.replace('"', "\"\""),
        table.replace('"', "\"\"")
    );
    let mut stmt = match conn.prepare(&sql) {
        Ok(s) => s,
        Err(_) => return String::new(),
    };
    let mut rows = match stmt.query([rowid]) {
        Ok(r) => r,
        Err(_) => return String::new(),
    };
    let Ok(Some(row)) = rows.next() else {
        return String::new();
    };
    decode_value(&row, 0)
}

/// 宽松读取整型列（INTEGER/REAL/TEXT 均可，对齐 sqlite3_column_int64 的宽松语义）
pub fn coerce_int(row: &rusqlite::Row<'_>, idx: usize) -> i64 {
    use rusqlite::types::ValueRef;
    match row.get_ref(idx) {
        Ok(ValueRef::Integer(v)) => v,
        Ok(ValueRef::Real(f)) => f as i64,
        Ok(ValueRef::Text(t)) => String::from_utf8_lossy(t).trim().parse().unwrap_or(0),
        _ => 0,
    }
}

/// 从 row 的第 `idx` 列解码文本/BLOB
pub fn decode_value(row: &rusqlite::Row<'_>, idx: usize) -> String {
    use rusqlite::types::ValueRef;
    match row.get_ref(idx) {
        Ok(ValueRef::Text(t)) => String::from_utf8_lossy(t).into_owned(),
        Ok(ValueRef::Blob(b)) => {
            // 先按 UTF-8 试，含 NUL 则按 UTF-16LE 试，否则占位
            if let Ok(s) = std::str::from_utf8(b) {
                if !s.contains('\0') {
                    return s.to_string();
                }
            }
            if b.len() % 2 == 0 {
                let mut u16 = Vec::with_capacity(b.len() / 2);
                for chunk in b.chunks_exact(2) {
                    u16.push(u16::from_le_bytes([chunk[0], chunk[1]]));
                }
                if let Ok(s) = String::from_utf16(&u16) {
                    return s;
                }
            }
            "[压缩内容未解码]".to_string()
        }
        _ => String::new(),
    }
}
