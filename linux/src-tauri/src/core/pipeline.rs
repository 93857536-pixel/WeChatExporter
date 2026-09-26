//! 导出编排（GUI / wce CLI / 定时任务共用）：导出 → 过滤 → 脱敏 → 索引 → 报告/日历 → 水印兜底

use crate::core::contact_store;
use crate::core::models::{self, ContactItem, Message};
use crate::core::settings::Settings;
use crate::core::watermark::Watermark;
use crate::core::{chat_exporter, filter, single_file, stats_report, util, Result};
use std::path::Path;

use serde::Serialize;

#[derive(Debug, Clone, Default, Serialize)]
pub struct ExportSummary {
    pub contacts: usize,
    pub total_messages: i64,
    pub output_root: String,
    pub lines: Vec<String>,
}

/// 导出选中的会话（完整后处理管线）
pub fn export_selected(
    decrypted_dir: &Path,
    output_root: &Path,
    selected: &[ContactItem],
    settings: &Settings,
    log: &mut dyn FnMut(String),
) -> Result<ExportSummary> {
    std::fs::create_dir_all(output_root)
        .map_err(|e| crate::core::err(format!("创建导出目录失败：{e}")))?;

    let wm = Watermark {
        enabled: settings.export.watermark_enabled,
        text: settings.export.watermark_text.clone(),
    };
    let (from_ts, to_ts) = filter::date_range_ts(
        &settings.export.filter.from_date,
        &settings.export.filter.to_date,
    );
    let keywords = filter::parse_keywords(&settings.export.filter.keywords);

    let mut summary = ExportSummary {
        contacts: selected.len(),
        output_root: output_root.to_string_lossy().into_owned(),
        ..Default::default()
    };

    for contact in selected {
        let dir_name = models::sanitize_filename(&contact.display_name);
        let contact_dir = output_root.join(&dir_name);
        std::fs::create_dir_all(&contact_dir)
            .map_err(|e| crate::core::err(format!("创建会话目录失败：{e}")))?;

        let count = chat_exporter::export(contact, decrypted_dir, &contact_dir)?;
        summary.total_messages += count;
        log(format!("导出：{}（{count} 条）", contact.display_name));

        // 过滤（SPEC §4：区间 + 关键词）
        let mut kept = count;
        if settings.export.filter.enabled {
            if let Ok(data) = std::fs::read_to_string(contact_dir.join("chat.json")) {
                if let Ok(all) = serde_json::from_str::<Vec<Message>>(&data) {
                    let filtered = filter::filter_messages(&all, from_ts, to_ts, &keywords);
                    kept = filtered.len() as i64;
                    if kept == 0 {
                        summary.lines.push(format!(
                            "• {}：过滤后 0 条命中，跳过报告",
                            contact.display_name
                        ));
                        continue;
                    }
                    chat_exporter::write_artifacts(contact, &filtered, &contact_dir)?;
                    log(format!(
                        "过滤后保留 {kept} / {count} 条（{}）",
                        contact.display_name
                    ));
                }
            }
        }

        // 统计报告 + 单文件 HTML（基于过滤后的 chat.json）
        if settings.export.stats_report {
            let _ =
                stats_report::write_report(&contact_dir, &contact.display_name, output_root, &wm)?;
        }
        if let Ok(url) =
            single_file::write_html(&contact_dir, &contact.display_name, output_root, &wm)
        {
            log(format!(
                "单文件 HTML：{}",
                url.file_name().unwrap_or_default().to_string_lossy()
            ));
        }
        summary
            .lines
            .push(format!("• {}：{kept} 条", contact.display_name));
    }

    // 脱敏（SPEC §3）
    if settings.export.anon.enabled {
        let map = crate::core::anon::anonymize_directory(
            output_root,
            settings.export.anon.mask_pii,
            settings.export.anon.keep_mapping,
            log,
        )?;
        let mapping_file = output_root.join("anonymization-map.json");
        let payload = serde_json::json!({
            "version": 1,
            "generated_at": util::now_local_iso(),
            "name_map": map,
            "note": "删除此文件即不可逆"
        });
        std::fs::write(
            &mapping_file,
            serde_json::to_string_pretty(&payload).unwrap(),
        )
        .ok();
        if !settings.export.anon.keep_mapping {
            let _ = std::fs::remove_file(&mapping_file);
            summary
                .lines
                .push("已脱敏（不可逆，映射已销毁）".to_string());
        } else {
            summary.lines.push("已脱敏（映射文件在根目录）".to_string());
        }
    }

    // 搜索索引（SPEC §1）
    if settings.export.search_index {
        crate::core::search_index::build_index(output_root, log)?;
    }

    // 年度报告 + 日历（SPEC §5/§6）
    if settings.export.annual_report {
        let _ = crate::core::annual_report::write_report(output_root, &wm, log)?;
    }
    if settings.export.calendar_extract {
        let _ = crate::core::calendar::write_events(output_root, log)?;
    }

    // 目录导航页 index.html
    if settings.export.index_page {
        let _ = write_index_page(output_root, &wm);
    }

    // 水印幂等兜底
    let _ = wm.apply_to_directory(output_root, log);

    // 记住最近导出目录
    {
        let mut s = settings.clone();
        s.export.last_dir = output_root.to_string_lossy().into_owned();
        let _ = crate::core::settings::save(&s);
    }

    Ok(summary)
}

/// 生成导出根目录的导航页 index.html（含会话链接与离线搜索提示）
fn write_index_page(output_root: &Path, wm: &Watermark) -> Result<()> {
    let mut links = String::new();
    if let Ok(entries) = std::fs::read_dir(output_root) {
        let mut dirs: Vec<(String, String)> = Vec::new();
        for e in entries.filter_map(|e| e.ok()) {
            let p = e.path();
            if p.is_dir() && p.join("chat.json").exists() {
                let name = e.file_name().to_string_lossy().into_owned();
                // 找该会话的单文件 HTML 链接
                if let Ok(sub) = std::fs::read_dir(output_root) {
                    for se in sub.filter_map(|s| s.ok()) {
                        let sp = se.path();
                        if sp.is_file() && sp.extension().map(|x| x == "html").unwrap_or(false) {
                            let fname = se.file_name().to_string_lossy().into_owned();
                            if fname.starts_with(&name) {
                                dirs.push((name.clone(), fname));
                                break;
                            }
                        }
                    }
                }
                if !dirs.iter().any(|(n, _)| n == &name) {
                    dirs.push((name, String::new()));
                }
            }
        }
        dirs.sort();
        for (name, html) in dirs {
            if html.is_empty() {
                links.push_str(&format!("<li>{}</li>\n", models::escape_html(&name)));
            } else {
                links.push_str(&format!(
                    "<li><a href=\"{}\">{}</a></li>\n",
                    models::escape_html(&html),
                    models::escape_html(&name)
                ));
            }
        }
    }

    let html = format!(
        "<!DOCTYPE html>\n<html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\
         <title>导出目录</title><style>{STYLES}</style></head><body>{overlay}\
         <header><h1>🛰️ WeChatExporter 导出目录</h1><p class=\"sub\">共 {} 个会话 · 生成于 {}</p></header>\
         <main><ul class=\"links\">{links}</ul></main>{footer}</body></html>",
        dirs_count(&links),
        util::now_local_hm(),
        overlay = wm.html_overlay(false),
        links = links,
        footer = wm.html_footer(),
    );
    std::fs::write(output_root.join("index.html"), html)
        .map_err(|e| crate::core::err(format!("写 index.html 失败：{e}")))?;
    Ok(())
}

fn dirs_count(_links: &str) -> usize {
    // 由 write_index_page 内部统计；这里简化返回链接条数
    _links.matches("<li>").count()
}

/// 无头导出入口（wce export）：加载全部/指定会话并导出
pub fn export_all(
    decrypted_dir: &Path,
    output_root: &Path,
    contact_ids: &[String],
    settings: &Settings,
    log: &mut dyn FnMut(String),
) -> Result<ExportSummary> {
    let contacts = contact_store::load_contacts(decrypted_dir)?;
    let selected: Vec<ContactItem> = if contact_ids.is_empty() {
        contacts.clone()
    } else {
        contacts
            .into_iter()
            .filter(|c| contact_ids.contains(&c.id))
            .collect()
    };
    if selected.is_empty() {
        return Err(crate::core::err("没有可导出的会话"));
    }
    export_selected(decrypted_dir, output_root, &selected, settings, log)
}

const STYLES: &str = r#"
    :root { --bg:#0b1026; --cyan:#00f5ff; --purple:#7b61ff; --text:#f0f8ff; --sub:#9aa7c7; }
    * { box-sizing:border-box; }
    body { margin:0; padding:32px 16px; background:radial-gradient(1200px 600px at 50% -100px,#1b2a5e 0%,var(--bg) 60%); color:var(--text); font-family:-apple-system,"PingFang SC","Microsoft YaHei","Noto Sans CJK SC",sans-serif; }
    header, main { max-width:860px; margin:0 auto; }
    header { text-align:center; margin-bottom:28px; }
    h1 { font-size:26px; margin:0 0 8px; background:linear-gradient(92deg,var(--cyan),var(--purple)); -webkit-background-clip:text; background-clip:text; color:transparent; }
    .sub { color:var(--sub); font-size:13px; }
    .links { list-style:none; padding:0; }
    .links li { background:rgba(255,255,255,0.05); border:1px solid rgba(0,245,255,0.18); border-radius:12px; padding:14px 18px; margin-bottom:10px; }
    .links a { color:var(--cyan); text-decoration:none; }
    .links a:hover { text-shadow:0 0 10px rgba(0,245,255,0.5); }
"#;
