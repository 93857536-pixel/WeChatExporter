//! 无头 `wce` CLI（SPEC §7）。用法：`<exe> wce <subcommand>`

use crate::core::settings::Settings;
use std::path::PathBuf;

pub fn run(args: &[String]) -> i32 {
    // args[0] == "wce"
    let rest = &args[1..];
    let cmd = rest.first().map(|s| s.as_str()).unwrap_or("--help");
    match cmd {
        "--version" | "-V" => {
            println!("wce {}", env!("CARGO_PKG_VERSION"));
            0
        }
        "--help" | "-h" | "" => {
            print_help();
            0
        }
        "--auto-sync" => {
            let settings = Settings::load();
            let mut log = |m: String| {
                println!("{m}");
                crate::core::autosync::append_log(&m);
            };
            crate::core::autosync::run_auto_sync(&settings, &mut log)
        }
        "search" => cmd_search(rest),
        "index" => cmd_index(rest),
        "report" => cmd_report(rest),
        "export" => cmd_export(rest),
        other => {
            eprintln!("未知子命令：{other}");
            print_help();
            2
        }
    }
}

fn print_help() {
    println!(
        "WeChatExporter 无头 CLI (Linux)\n\n\
         用法：<exe> wce <子命令> [参数]\n\n\
         子命令：\n  \
         --auto-sync            跑一次定时增量导出（读设置）\n  \
         search <kw> [--dir D]  无头搜索，stdout 打印前 20 条\n  \
         index  [--dir D]       重建搜索索引（不导出）\n  \
         report [--dir D]       重生成年度报告+日历（不导出）\n  \
         export <dbdir> <out>   导出指定已解密目录到输出目录（全部会话）\n  \
         --version              打印版本\n  \
         --help                 打印帮助\n"
    );
}

fn settings_export_dir() -> PathBuf {
    let s = Settings::load();
    if s.export.last_dir.is_empty() {
        PathBuf::from(".")
    } else {
        PathBuf::from(s.export.last_dir)
    }
}

fn parse_dir_flag(rest: &[String]) -> PathBuf {
    // 找 --dir 后面的参数
    for i in 0..rest.len() {
        if rest[i] == "--dir" {
            if let Some(d) = rest.get(i + 1) {
                return PathBuf::from(d);
            }
        }
    }
    settings_export_dir()
}

fn cmd_search(rest: &[String]) -> i32 {
    let kw = rest.get(1).cloned().unwrap_or_default();
    if kw.is_empty() {
        eprintln!("用法：wce search <关键词> [--dir <导出根>]");
        return 2;
    }
    let dir = parse_dir_flag(rest);
    match crate::core::search_index::search(&dir, &kw, 20) {
        Ok(hits) => {
            for h in &hits {
                println!(
                    "[{}] {} {}：{}",
                    crate::core::util::format_time(h.ts),
                    h.chat,
                    h.sender,
                    h.content.chars().take(80).collect::<String>()
                );
            }
            if hits.is_empty() {
                println!("（无结果）");
            }
            0
        }
        Err(e) => {
            eprintln!("搜索失败：{e}");
            1
        }
    }
}

fn cmd_index(rest: &[String]) -> i32 {
    let dir = parse_dir_flag(rest);
    let mut log = |m: String| println!("{m}");
    match crate::core::search_index::build_index(&dir, &mut log) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("重建索引失败：{e}");
            1
        }
    }
}

fn cmd_report(rest: &[String]) -> i32 {
    let dir = parse_dir_flag(rest);
    let settings = Settings::load();
    let wm = crate::core::watermark::Watermark {
        enabled: settings.export.watermark_enabled,
        text: settings.export.watermark_text.clone(),
    };
    let mut log = |m: String| println!("{m}");
    let _ = crate::core::annual_report::write_report(&dir, &wm, &mut log);
    let _ = crate::core::calendar::write_events(&dir, &mut log);
    0
}

fn cmd_export(rest: &[String]) -> i32 {
    let dbdir = rest.get(1).cloned();
    let out = rest.get(2).cloned();
    let (Some(dbdir), Some(out)) = (dbdir, out) else {
        eprintln!("用法：wce export <已解密目录> <输出目录>");
        return 2;
    };
    let settings = Settings::load();
    let mut log = |m: String| println!("{m}");
    match crate::core::pipeline::export_all(
        &PathBuf::from(dbdir),
        &PathBuf::from(out),
        &[],
        &settings,
        &mut log,
    ) {
        Ok(s) => {
            println!(
                "导出完成：{} 个会话，共 {} 条消息",
                s.contacts, s.total_messages
            );
            0
        }
        Err(e) => {
            eprintln!("导出失败：{e}");
            1
        }
    }
}
