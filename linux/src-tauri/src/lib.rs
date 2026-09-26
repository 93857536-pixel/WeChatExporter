//! 库根：导出核心引擎 + wce CLI + Tauri 应用入口

pub mod cli;
pub mod commands;
pub mod core;

/// 启动 Tauri GUI
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            commands::load_contacts,
            commands::pick_directory,
            commands::export_contacts,
            commands::get_settings,
            commands::save_settings,
            commands::search,
            commands::install_timer,
            commands::uninstall_timer,
            commands::timer_status,
            commands::encrypt_export,
        ])
        .run(tauri::generate_context!())
        .expect("error while running WeChatExporter");
}
