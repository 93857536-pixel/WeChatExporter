//! Tauri 命令处理器（前端 invoke 接口）

use crate::core::models::ContactItem;
use crate::core::pipeline::ExportSummary;
use crate::core::search_index::SearchHit;
use crate::core::settings::Settings;
use std::path::Path;
use tauri::Emitter;
use tauri_plugin_dialog::DialogExt;

/// 加载已解密目录下的会话列表
#[tauri::command]
pub fn load_contacts(data_dir: String) -> Result<Vec<ContactItem>, String> {
    crate::core::contact_store::load_contacts(Path::new(&data_dir)).map_err(|e| e.to_string())
}

/// 选择目录（系统文件夹对话框）
#[tauri::command]
pub async fn pick_directory(app: tauri::AppHandle) -> Result<Option<String>, String> {
    let picked = app.dialog().file().blocking_pick_folder();
    Ok(picked
        .and_then(|p| p.into_path().ok())
        .map(|p| p.to_string_lossy().into_owned()))
}

/// 导出选中的会话（完整后处理管线，进度/日志通过 `wce:log` 事件推送）
#[tauri::command]
pub async fn export_contacts(
    app: tauri::AppHandle,
    data_dir: String,
    output_dir: String,
    contact_ids: Vec<String>,
) -> Result<ExportSummary, String> {
    let settings = Settings::load();
    tauri::async_runtime::spawn_blocking(move || {
        let contacts = crate::core::contact_store::load_contacts(Path::new(&data_dir))
            .map_err(|e| e.to_string())?;
        let selected: Vec<ContactItem> = if contact_ids.is_empty() {
            contacts.clone()
        } else {
            contacts
                .into_iter()
                .filter(|c| contact_ids.contains(&c.id))
                .collect()
        };
        if selected.is_empty() {
            return Err("没有可导出的会话".to_string());
        }
        let mut log = |line: String| {
            let _ = app.emit("wce:log", line);
        };
        crate::core::pipeline::export_selected(
            Path::new(&data_dir),
            Path::new(&output_dir),
            &selected,
            &settings,
            &mut log,
        )
        .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

/// 读取当前设置
#[tauri::command]
pub fn get_settings() -> Settings {
    Settings::load()
}

/// 保存设置
#[tauri::command]
pub fn save_settings(settings: Settings) -> Result<(), String> {
    crate::core::settings::save(&settings).map_err(|e| e.to_string())
}

/// 搜索（打开最近导出目录的 wce-search.sqlite）
#[tauri::command]
pub fn search(keyword: String, export_dir: Option<String>) -> Result<Vec<SearchHit>, String> {
    let dir = export_dir
        .map(std::path::PathBuf::from)
        .or_else(|| {
            let s = Settings::load();
            if s.export.last_dir.is_empty() {
                None
            } else {
                Some(std::path::PathBuf::from(s.export.last_dir))
            }
        })
        .ok_or_else(|| "未找到导出目录，请先导出".to_string())?;
    crate::core::search_index::search(&dir, &keyword, 200).map_err(|e| e.to_string())
}

/// 安装 systemd 定时任务
#[tauri::command]
pub fn install_timer(interval_minutes: i64) -> Result<String, String> {
    crate::core::autosync::install_timer(interval_minutes).map_err(|e| e.to_string())
}

/// 卸载 systemd 定时任务
#[tauri::command]
pub fn uninstall_timer() -> Result<String, String> {
    crate::core::autosync::uninstall_timer().map_err(|e| e.to_string())
}

/// 定时任务状态
#[tauri::command]
pub fn timer_status() -> String {
    let s = Settings::load();
    crate::core::autosync::timer_status(&s)
}

/// 加密导出目录为 .wxenc（返回目标文件路径）
#[tauri::command]
pub async fn encrypt_export(dir: String, password: String, dest: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let mut log = |_m: String| {};
        crate::core::encrypted::encrypt_directory(
            Path::new(&dir),
            &password,
            Path::new(&dest),
            &mut log,
        )
        .map(|_| dest)
        .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}
