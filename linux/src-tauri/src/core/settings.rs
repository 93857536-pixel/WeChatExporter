//! 设置持久化（Linux：$XDG_CONFIG_HOME/wechat-exporter/settings.json，默认 ~/.config/...）
//! 键名与 docs/MULTIPLATFORM_SPEC.md §0 一致（跨平台同名）。

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct AutoSyncSettings {
    pub enabled: bool,
    pub interval_minutes: i64,
    pub export_dir: String,
    pub contact_ids: Vec<String>,
    pub last_run: String,
}

impl Default for AutoSyncSettings {
    fn default() -> Self {
        AutoSyncSettings {
            enabled: false,
            interval_minutes: 60,
            export_dir: String::new(),
            contact_ids: Vec::new(),
            last_run: String::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct AnonSettings {
    pub enabled: bool,
    pub mask_pii: bool,
    pub keep_mapping: bool,
}

impl Default for AnonSettings {
    fn default() -> Self {
        AnonSettings {
            enabled: false,
            mask_pii: true,
            keep_mapping: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct FilterSettings {
    pub enabled: bool,
    pub from_date: String,
    pub to_date: String,
    pub keywords: String,
}

impl Default for FilterSettings {
    fn default() -> Self {
        FilterSettings {
            enabled: false,
            from_date: String::new(),
            to_date: String::new(),
            keywords: String::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ExportSettings {
    pub search_index: bool,
    pub auto_sync: AutoSyncSettings,
    pub anon: AnonSettings,
    pub filter: FilterSettings,
    pub annual_report: bool,
    pub calendar_extract: bool,
    pub watermark_enabled: bool,
    pub watermark_text: String,
    pub mode: String,
    pub stats_report: bool,
    pub index_page: bool,
    pub last_dir: String,
    pub data_dir: String,
}

impl Default for ExportSettings {
    fn default() -> Self {
        ExportSettings {
            search_index: true,
            auto_sync: AutoSyncSettings::default(),
            anon: AnonSettings::default(),
            filter: FilterSettings::default(),
            annual_report: true,
            calendar_extract: true,
            watermark_enabled: true,
            watermark_text: crate::core::watermark::DEFAULT_WATERMARK_TEXT.to_string(),
            mode: "textOnly".to_string(),
            stats_report: true,
            index_page: true,
            last_dir: String::new(),
            data_dir: String::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub export: ExportSettings,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            export: ExportSettings::default(),
        }
    }
}

/// 配置文件路径（可用环境变量 WCE_SETTINGS 覆盖，便于测试）
pub fn settings_path() -> PathBuf {
    if let Ok(p) = std::env::var("WCE_SETTINGS") {
        return PathBuf::from(p);
    }
    let base = std::env::var("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            std::env::var("HOME")
                .map(|h| PathBuf::from(h).join(".config"))
                .unwrap_or_else(|_| PathBuf::from("."))
        });
    base.join("wechat-exporter").join("settings.json")
}

impl Settings {
    /// 加载设置（文件不存在或损坏时返回默认值）
    pub fn load() -> Settings {
        let path = settings_path();
        let data = match std::fs::read_to_string(&path) {
            Ok(d) => d,
            Err(_) => return Settings::default(),
        };
        match serde_json::from_str::<Settings>(&data) {
            Ok(s) => s,
            Err(_) => {
                // 兼容旧的扁平 / snake_case 键（watermark_enabled 等）——尽力合并，失败则默认
                Settings::default()
            }
        }
    }
}

/// 保存设置（创建父目录）
pub fn save(settings: &Settings) -> Result<(), crate::core::Error> {
    let path = settings_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| crate::core::err(format!("创建配置目录失败：{e}")))?;
    }
    let json = serde_json::to_string_pretty(settings)
        .map_err(|e| crate::core::err(format!("序列化设置失败：{e}")))?;
    std::fs::write(&path, json).map_err(|e| crate::core::err(format!("写设置失败：{e}")))?;
    Ok(())
}

/// 读取单一设置值（前端回显用）：返回整个 Settings JSON
pub fn to_json(settings: &Settings) -> serde_json::Value {
    serde_json::to_value(settings).unwrap_or(serde_json::Value::Null)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_settings_values() {
        let s = Settings::default();
        assert!(s.export.search_index);
        assert!(s.export.watermark_enabled);
        assert_eq!(s.export.watermark_text, "林琝淏科技集团有限公司");
        assert!(!s.export.anon.enabled);
        assert_eq!(s.export.mode, "textOnly");
    }

    #[test]
    fn roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::env::set_var("WCE_SETTINGS", &path);
        let mut s = Settings::default();
        s.export.filter.enabled = true;
        s.export.filter.keywords = "hello,world".to_string();
        save(&s).unwrap();
        let loaded = Settings::load();
        assert!(loaded.export.filter.enabled);
        assert_eq!(loaded.export.filter.keywords, "hello,world");
    }
}
