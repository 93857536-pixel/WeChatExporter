//! 定时增量导出（SPEC §2）：systemd user timer 安装/卸载/状态 + `wce --auto-sync` 运行器

use crate::core::settings::Settings;
use crate::core::Result;
use std::path::PathBuf;

const SERVICE_NAME: &str = "wce-autosync.service";
const TIMER_NAME: &str = "wce-autosync.timer";

fn systemd_user_dir() -> PathBuf {
    let base = std::env::var("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            std::env::var("HOME")
                .map(|h| PathBuf::from(h).join(".config"))
                .unwrap_or_else(|_| PathBuf::from("."))
        });
    base.join("systemd").join("user")
}

/// 当前可执行文件路径（用于 systemd ExecStart）
fn current_exe() -> String {
    std::env::current_exe()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| "wechat-exporter-linux".to_string())
}

fn write_unit_files(interval_minutes: i64) -> Result<PathBuf> {
    let dir = systemd_user_dir();
    std::fs::create_dir_all(&dir)
        .map_err(|e| crate::core::err(format!("创建 systemd 目录失败：{e}")))?;

    let service = format!(
        "[Unit]\nDescription=WeChatExporter 定时增量导出\n\n[Service]\nType=oneshot\nExecStart={} wce --auto-sync\n",
        current_exe()
    );
    let timer = format!(
        "[Unit]\nDescription=WeChatExporter 定时增量导出定时器\n\n[Timer]\nOnUnitActiveSec={}m\n\n[Install]\nWantedBy=timers.target\n",
        interval_minutes.max(5)
    );
    std::fs::write(dir.join(SERVICE_NAME), service)
        .map_err(|e| crate::core::err(format!("写 service 失败：{e}")))?;
    std::fs::write(dir.join(TIMER_NAME), timer)
        .map_err(|e| crate::core::err(format!("写 timer 失败：{e}")))?;
    Ok(dir)
}

/// 安装 systemd user timer（返回状态信息）
pub fn install_timer(interval_minutes: i64) -> Result<String> {
    write_unit_files(interval_minutes)?;
    let _ = run_cmd("systemctl", &["--user", "daemon-reload"]);
    let _ = run_cmd("systemctl", &["--user", "enable", "--now", TIMER_NAME]);
    Ok(format!("已安装定时任务（每 {interval_minutes} 分钟）"))
}

/// 卸载 systemd user timer
pub fn uninstall_timer() -> Result<String> {
    let _ = run_cmd("systemctl", &["--user", "disable", "--now", TIMER_NAME]);
    let dir = systemd_user_dir();
    let _ = std::fs::remove_file(dir.join(SERVICE_NAME));
    let _ = std::fs::remove_file(dir.join(TIMER_NAME));
    let _ = run_cmd("systemctl", &["--user", "daemon-reload"]);
    Ok("已卸载定时任务".to_string())
}

/// 查询定时任务状态（已安装/未安装 + 上次运行时间）
pub fn timer_status(settings: &Settings) -> String {
    let installed = systemd_user_dir().join(TIMER_NAME).exists();
    let last_run = if settings.export.auto_sync.last_run.is_empty() {
        "从未运行".to_string()
    } else {
        settings.export.auto_sync.last_run.clone()
    };
    if installed {
        format!(
            "已安装 · 每 {} 分钟 · 上次运行：{last_run}",
            settings.export.auto_sync.interval_minutes
        )
    } else {
        format!("未安装 · 上次运行：{last_run}")
    }
}

fn run_cmd(cmd: &str, args: &[&str]) -> std::process::Output {
    std::process::Command::new(cmd)
        .args(args)
        .output()
        .unwrap_or_else(|_| std::process::Output {
            status: std::process::ExitStatus::default(),
            stdout: Vec::new(),
            stderr: Vec::new(),
        })
}

/// `wce --auto-sync`：读设置，若未启用直接退出 0；否则对子集/全部会话做增量导出
pub fn run_auto_sync(settings: &Settings, log: &mut dyn FnMut(String)) -> i32 {
    if !settings.export.auto_sync.enabled {
        log("auto-sync 未启用，退出".to_string());
        return 0;
    }
    let data_dir = std::env::var("WCE_DATA_DIR")
        .map(PathBuf::from)
        .ok()
        .or_else(|| {
            let s = settings.export.last_dir.clone();
            if s.is_empty() {
                None
            } else {
                Some(PathBuf::from(s))
            }
        });
    // data dir 由设置里的 last_dir 派生不可靠，优先用显式存储的 data_dir 键（见 settings.data_dir 扩展）
    // 这里从环境变量或 last_dir 目录推断；GUI 安装定时任务时会写 data_dir 到 settings。
    let Some(data_dir) = data_dir else {
        log("未配置数据目录，auto-sync 退出".to_string());
        return 1;
    };
    let export_dir = if settings.export.auto_sync.export_dir.is_empty() {
        data_dir.clone()
    } else {
        PathBuf::from(&settings.export.auto_sync.export_dir)
    };

    let result = crate::core::pipeline::export_all(
        &data_dir,
        &export_dir,
        &settings.export.auto_sync.contact_ids,
        settings,
        log,
    );
    match result {
        Ok(s) => {
            log(format!(
                "auto-sync 完成：{} 个会话，共 {} 条",
                s.contacts, s.total_messages
            ));
            0
        }
        Err(e) => {
            log(format!("auto-sync 失败：{e}"));
            1
        }
    }
}

/// 追加写日志到 autosync.log
pub fn append_log(msg: &str) {
    let dir = std::env::var("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            std::env::var("HOME")
                .map(|h| PathBuf::from(h).join(".local/state"))
                .unwrap_or_else(|_| PathBuf::from("."))
        })
        .join("wce");
    if std::fs::create_dir_all(&dir).is_ok() {
        let line = format!("[{}] {msg}\n", crate::core::util::now_local_iso());
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(dir.join("autosync.log"))
        {
            let _ = f.write_all(line.as_bytes());
        }
    }
}
