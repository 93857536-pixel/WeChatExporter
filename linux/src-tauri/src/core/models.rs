//! 数据模型（与 macOS `Models/ContactItem.swift` / `ChatExporter.Message` 对齐）

use serde::{Deserialize, Serialize};

/// 会话类型（与 macOS ContactKind 一致）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ContactKind {
    Friend,
    Group,
    Official,
}

impl ContactKind {
    pub fn label(&self) -> &'static str {
        match self {
            ContactKind::Friend => "好友",
            ContactKind::Group => "群聊",
            ContactKind::Official => "公众号",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContactItem {
    pub id: String,
    pub display_name: String,
    pub nick_name: String,
    pub remark: String,
    pub kind: ContactKind,
    pub last_time: String,
    pub last_timestamp: i64,
    pub summary: String,
}

impl ContactItem {
    pub fn subtitle(&self) -> String {
        if self.summary.is_empty() {
            self.last_time.clone()
        } else {
            format!("{} · {}", self.last_time, self.summary)
        }
    }
}

/// 单条消息（序列化字段与 macOS `ChatExporter.Message` 完全一致：
/// `time` / `timestamp` / `sender` / `type` / `typeName` / `content`）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub time: String,
    pub timestamp: i64,
    pub sender: String,
    #[serde(rename = "type")]
    pub msg_type: i32,
    #[serde(rename = "typeName")]
    pub type_name: String,
    pub content: String,
}

/// 消息类型中文名（与 macOS `msgTypes` 字典一致）
pub fn msg_type_name(t: i32) -> String {
    match t {
        1 => "文本".to_string(),
        3 => "图片".to_string(),
        34 => "语音".to_string(),
        42 => "名片".to_string(),
        43 => "视频".to_string(),
        47 => "表情".to_string(),
        48 => "位置".to_string(),
        49 => "链接/文件/小程序".to_string(),
        50 => "语音/视频通话".to_string(),
        51 => "系统消息".to_string(),
        10000 => "系统提示".to_string(),
        10002 => "撤回消息".to_string(),
        other => format!("未知({other})"),
    }
}

/// 媒体类消息（导出纯文字时折叠为占位符）
pub fn is_media_type(t: i32) -> bool {
    matches!(t, 3 | 34 | 43 | 47)
}

/// 系统提示 / 撤回消息（发送者固定为「系统」）
pub fn is_system_type(t: i32) -> bool {
    t == 10000 || t == 10002
}

/// 文件名净化（与 macOS `sanitizeFilename` 同口径：`.` 转空格、去掉非法字符）
pub fn sanitize_filename(s: &str) -> String {
    let no_dot = s.replace('.', " ");
    let cleaned: String = no_dot
        .chars()
        .filter(|c| !"/\\:*?\"<>|".contains(*c))
        .collect();
    if cleaned.trim().is_empty() {
        "聊天记录".to_string()
    } else {
        cleaned
    }
}

/// HTML 转义（& < > " 与 macOS escapeHTML 对齐）
pub fn escape_html(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}
