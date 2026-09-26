//! 导出核心引擎（平台无关，供 GUI / wce CLI / 集成测试共用）

pub mod annual_report;
pub mod anon;
pub mod autosync;
pub mod calendar;
pub mod chat_exporter;
pub mod contact_store;
pub mod db;
pub mod encrypted;
pub mod filter;
pub mod models;
pub mod pipeline;
pub mod search_index;
pub mod settings;
pub mod single_file;
pub mod stats_report;
pub mod util;
pub mod watermark;

/// 统一错误类型（简单字符串包装）
#[derive(Debug, Clone)]
pub struct Error(pub String);

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

/// 构造错误
pub fn err(msg: impl Into<String>) -> Error {
    Error(msg.into())
}
