//! 聊天统计报告（与 macOS `ChatStatsReport.swift` 同口径 + 同款暗色主题）

use crate::core::models::{self, Message};
use crate::core::watermark::Watermark;
use crate::core::{util, Result};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub fn write_report(
    source_dir: &Path,
    contact_name: &str,
    dest_dir: &Path,
    wm: &Watermark,
) -> Result<Option<PathBuf>> {
    let json_url = source_dir.join("chat.json");
    let json = match std::fs::read_to_string(&json_url) {
        Ok(s) => s,
        Err(_) => {
            return Ok(None); // 未找到 chat.json，跳过统计报告
        }
    };
    let rows: Vec<Message> = match serde_json::from_str(&json) {
        Ok(r) => r,
        Err(_) => return Ok(None),
    };
    if rows.is_empty() {
        return Ok(None);
    }

    // 聚合
    let mut hour_buckets: HashMap<u32, usize> = HashMap::new();
    let mut month_counts: HashMap<String, usize> = HashMap::new();
    let mut month_order: Vec<String> = Vec::new();
    let mut sender_counts: HashMap<String, usize> = HashMap::new();
    let mut total_chars: usize = 0;

    let mut timestamps: Vec<i64> = Vec::new();
    for row in &rows {
        if row.timestamp > 0 {
            timestamps.push(row.timestamp);
        }
        if let Some(hour) = util::hour_of(row.timestamp) {
            *hour_buckets.entry(hour).or_insert(0) += 1;
            let month = util::format_year_month(row.timestamp);
            if !month_counts.contains_key(&month) {
                month_order.push(month.clone());
            }
            *month_counts.entry(month).or_insert(0) += 1;
        }
        let sender = if row.sender.is_empty() {
            "未知".to_string()
        } else {
            row.sender.clone()
        };
        *sender_counts.entry(sender).or_insert(0) += 1;
        total_chars += row.content.chars().count();
    }

    let total_messages = rows.len();
    let mut top_senders: Vec<(String, usize)> = sender_counts.into_iter().collect();
    top_senders.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    top_senders.truncate(8);

    let peak_month = month_counts
        .iter()
        .max_by_key(|(_, v)| *v)
        .map(|(k, _)| k.clone());
    let avg_len = if total_messages > 0 {
        total_chars / total_messages
    } else {
        0
    };
    let earliest = timestamps.iter().min().copied();
    let latest = timestamps.iter().max().copied();

    let title = if contact_name.is_empty() {
        "聊天记录统计"
    } else {
        contact_name
    };
    let mut html = String::new();
    html.push_str("<!DOCTYPE html>\n<html lang=\"zh-CN\"><head><meta charset=\"utf-8\">");
    html.push_str("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">");
    html.push_str(&format!(
        "<title>{}</title>",
        models::escape_html(&format!("{title} 统计"))
    ));
    html.push_str(&format!("<style>{}</style></head><body>", REPORT_STYLES));
    html.push_str(&wm.html_overlay(false));
    html.push_str(&format!(
        "<header><h1>📊 {} · 统计报告</h1>",
        models::escape_html(title)
    ));
    let range = match (earliest, latest) {
        (Some(a), Some(b)) => format!("{} 至 {}", util::format_time(a), util::format_time(b)),
        _ => "—".to_string(),
    };
    html.push_str(&format!(
        "<p class=\"sub\">数据范围：{range}　·　共 {total_messages} 条消息　·　生成于 {}</p></header>",
        util::now_local_hm()
    ));

    // 概览卡片
    html.push_str("<section class=\"cards\">");
    html.push_str(&format!(
        "<div class=\"card\"><div class=\"num\">{total_messages}</div><div>消息总数</div></div>"
    ));
    html.push_str("<div class=\"card\"><div class=\"num\">0</div><div>媒体附件</div></div>");
    html.push_str(&format!(
        "<div class=\"card\"><div class=\"num\">{}</div><div>参与者</div></div>",
        top_senders.len()
    ));
    html.push_str(&format!(
        "<div class=\"card\"><div class=\"num\">{avg_len}</div><div>平均字数/条</div></div>"
    ));
    html.push_str("</section>");

    // 发言排行
    html.push_str("<section><h2>发言排行</h2>");
    if !top_senders.is_empty() {
        let max_count = top_senders[0].1.max(1);
        for (name, count) in &top_senders {
            let pct = (count * 100 / max_count).max(3);
            let share = if total_messages > 0 {
                format!("{:.1}%", *count as f64 / total_messages as f64 * 100.0)
            } else {
                "0%".to_string()
            };
            html.push_str(&format!(
                "<div class=\"bar-row\"><span class=\"bar-label\">{}</span>\
                 <div class=\"bar-track\"><div class=\"bar\" style=\"width:{pct}%\"></div></div>\
                 <span class=\"bar-value\">{count}（{share}）</span></div>",
                models::escape_html(name)
            ));
        }
    } else {
        html.push_str("<p class=\"sub\">无发言数据</p>");
    }
    html.push_str("</section>");

    // 24 小时活跃分布
    html.push_str("<section><h2>24 小时活跃分布</h2><div class=\"hours\">");
    let max_hour = hour_buckets.values().copied().max().unwrap_or(1).max(1);
    for hour in 0..24 {
        let count = hour_buckets.get(&hour).copied().unwrap_or(0);
        let h = (count as f64 / max_hour as f64 * 100.0).round() as usize;
        html.push_str(&format!(
            "<div class=\"hour-cell\"><div class=\"hour-bar\" style=\"height:{h}%\" title=\"{count} 条\"></div><span>{hour}时</span></div>"
        ));
    }
    html.push_str("</div></section>");

    // 月度趋势
    html.push_str("<section><h2>月度消息量</h2>");
    if !month_order.is_empty() {
        let mut sorted_months = month_order.clone();
        sorted_months.sort();
        let max_month = month_counts.values().copied().max().unwrap_or(1).max(1);
        for m in sorted_months {
            let c = month_counts.get(&m).copied().unwrap_or(0);
            let w = (c as f64 / max_month as f64 * 100.0).round().max(2.0) as usize;
            let trophy = if peak_month.as_deref() == Some(m.as_str()) {
                " 🏆"
            } else {
                ""
            };
            html.push_str(&format!(
                "<div class=\"bar-row\"><span class=\"bar-label\">{}{trophy}</span>\
                 <div class=\"bar-track\"><div class=\"bar\" style=\"width:{w}%\"></div></div>\
                 <span class=\"bar-value\">{c}</span></div>",
                models::escape_html(&m)
            ));
        }
    } else {
        html.push_str("<p class=\"sub\">无时间数据</p>");
    }
    html.push_str("</section>");

    // 媒体构成（文本后端无媒体，固定提示）
    html.push_str("<section><h2>媒体构成</h2><p class=\"sub\">本次导出无媒体附件</p></section>");

    html.push_str(&format!(
        "<footer>由 WeChatExporter 本地生成 · 数据未离开你的设备{}</footer></body></html>",
        wm.html_footer()
    ));

    let safe_name = models::sanitize_filename(contact_name);
    let out_url = dest_dir.join(format!("{safe_name}_统计_{}.html", util::file_stamp()));
    std::fs::create_dir_all(dest_dir)
        .map_err(|e| crate::core::err(format!("创建目录失败：{e}")))?;
    std::fs::write(&out_url, html)
        .map_err(|e| crate::core::err(format!("统计报告写入失败：{e}")))?;
    Ok(Some(out_url))
}

/// 统计报告暗色科技风（与导出页同一主题：--bg #0b1026 / --cyan #00f5ff / --purple #7b61ff）
const REPORT_STYLES: &str = r#"
    :root { --bg: #0b1026; --card: rgba(255,255,255,0.05); --cyan: #00f5ff; --purple: #7b61ff; --text: #f0f8ff; --sub: #9aa7c7; }
    * { box-sizing: border-box; }
    body { margin: 0; padding: 32px 16px; background: radial-gradient(1200px 600px at 50% -100px, #1b2a5e 0%, var(--bg) 60%); color: var(--text); font-family: -apple-system, "PingFang SC", "Microsoft YaHei", "Noto Sans CJK SC", sans-serif; }
    .container, header, section { max-width: 860px; margin: 0 auto; }
    header { text-align: center; margin-bottom: 28px; }
    h1 { font-size: 26px; margin: 0 0 8px; }
    .sub { color: var(--sub); font-size: 13px; }
    .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px; margin-bottom: 28px; }
    .card { background: var(--card); border: 1px solid rgba(0,245,255,0.18); border-radius: 14px; padding: 18px; text-align: center; }
    .card .num { font-size: 30px; font-weight: 700; color: var(--cyan); }
    section { background: var(--card); border: 1px solid rgba(0,245,255,0.14); border-radius: 14px; padding: 20px; margin-bottom: 20px; }
    h2 { font-size: 17px; margin: 0 0 14px; color: var(--cyan); }
    .bar-row { display: flex; align-items: center; gap: 10px; margin: 8px 0; font-size: 13px; }
    .bar-label { width: 120px; text-align: right; color: var(--text); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bar-track { flex: 1; height: 14px; background: rgba(255,255,255,0.07); border-radius: 7px; overflow: hidden; }
    .bar { height: 100%; background: linear-gradient(90deg, var(--cyan), var(--purple)); border-radius: 7px; }
    .bar-value { width: 90px; color: var(--sub); }
    .hours { display: grid; grid-template-columns: repeat(12, 1fr); gap: 6px; }
    .hour-cell { text-align: center; font-size: 11px; color: var(--sub); }
    .hour-bar { margin: 0 auto 4px; width: 70%; min-height: 3px; height: 60px; display: flex; align-items: flex-end; background: linear-gradient(180deg, var(--cyan), var(--purple)); border-radius: 4px 4px 0 0; }
    footer { text-align: center; color: var(--sub); font-size: 12px; margin-top: 24px; }
"#;
