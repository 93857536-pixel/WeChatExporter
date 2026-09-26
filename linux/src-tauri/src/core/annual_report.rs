//! 年度可视化报告（SPEC §5）：聚合所有会话 chat.json，生成 `年度报告_<YYYY>.html`
//! 暗色科技风（--bg #0b1026 / --cyan #00f5ff / --purple #7b61ff），单文件纯内嵌 CSS。

use crate::core::models::Message;
use crate::core::util;
use chrono::{Datelike, TimeZone};
use crate::core::watermark::Watermark;
use crate::core::Result;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// 常见中文停用词（词频统计用）
const STOPWORDS: &[&str] = &[
    "的",
    "了",
    "我",
    "你",
    "是",
    "在",
    "有",
    "和",
    "就",
    "不",
    "人",
    "都",
    "一",
    "个",
    "上",
    "也",
    "很",
    "到",
    "说",
    "要",
    "去",
    "会",
    "着",
    "没",
    "看",
    "好",
    "这",
    "那",
    "们",
    "他",
    "她",
    "它",
    "吗",
    "呢",
    "吧",
    "啊",
    "哦",
    "嗯",
    "呀",
    "还",
    "又",
    "再",
    "被",
    "把",
    "让",
    "给",
    "跟",
    "与",
    "及",
    "或",
    "但",
    "而",
    "于",
    "以",
    "为",
    "所",
    "之",
    "其",
    "才",
    "只",
    "太",
    "很",
    "最",
    "更",
    "越",
    "没",
    "无",
    "非",
    "么",
    "什",
    "什么",
    "怎么",
    "为什么",
    "多少",
    "几",
    "哪",
    "哪里",
];

pub fn write_report(
    export_root: &Path,
    wm: &Watermark,
    log: &mut dyn FnMut(String),
) -> Result<Option<PathBuf>> {
    // 扫描所有会话 chat.json
    let mut all_messages: Vec<(String, Message)> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(export_root) {
        for e in entries.filter_map(|e| e.ok()) {
            let p = e.path();
            if !p.is_dir() {
                continue;
            }
            let json = p.join("chat.json");
            if !json.exists() {
                continue;
            }
            let chat = e.file_name().to_string_lossy().into_owned();
            if let Ok(data) = std::fs::read_to_string(&json) {
                if let Ok(msgs) = serde_json::from_str::<Vec<Message>>(&data) {
                    for m in msgs {
                        all_messages.push((chat.clone(), m));
                    }
                }
            }
        }
    }
    if all_messages.is_empty() {
        return Ok(None);
    }

    let session_count = {
        let mut s: std::collections::HashSet<String> = std::collections::HashSet::new();
        for (c, _) in &all_messages {
            s.insert(c.clone());
        }
        s.len()
    };
    let total = all_messages.len();

    // 活跃天数 / 月度 / 小时 / 发送者
    let mut active_days: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut month_counts: HashMap<String, usize> = HashMap::new();
    let mut hour_counts: HashMap<u32, usize> = HashMap::new();
    let mut sender_counts: HashMap<String, usize> = HashMap::new();
    let mut word_counts: HashMap<String, usize> = HashMap::new();
    let mut max_year = 0i32;

    for (chat, msg) in &all_messages {
        if msg.timestamp > 0 {
            active_days.insert(util::format_date(msg.timestamp));
            let month = util::format_year_month(msg.timestamp);
            *month_counts.entry(month).or_insert(0) += 1;
            if let Some(h) = util::hour_of(msg.timestamp) {
                *hour_counts.entry(h).or_insert(0) += 1;
            }
            if let chrono::LocalResult::Single(dt) = util::shanghai_offset().timestamp_opt(
                if msg.timestamp > 100_000_000_000 {
                    msg.timestamp / 1000
                } else {
                    msg.timestamp
                },
                0,
            ) {
                max_year = max_year.max(dt.year());
            }
        }
        let sender = if msg.sender.is_empty() {
            chat.clone()
        } else {
            msg.sender.clone()
        };
        *sender_counts.entry(sender).or_insert(0) += 1;

        for (w, c) in tokenize(&msg.content) {
            *word_counts.entry(w).or_insert(0) += c;
        }
    }

    let year = if max_year > 0 {
        max_year
    } else {
        chrono::Local::now().year()
    };

    // 词频 top30
    let mut top_words: Vec<(String, usize)> = word_counts.into_iter().collect();
    top_words.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    top_words.truncate(30);

    // 发言排行 top10
    let mut top_senders: Vec<(String, usize)> = sender_counts.into_iter().collect();
    top_senders.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    top_senders.truncate(10);

    // 峰值月份
    let peak_month = month_counts
        .iter()
        .max_by_key(|(_, v)| *v)
        .map(|(k, _)| k.clone());

    // 概览
    let mut html = String::new();
    html.push_str(&format!("<!DOCTYPE html>\n<html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>年度报告 {year}</title><style>{STYLES}</style></head><body>"));
    html.push_str(&wm.html_overlay(false));
    html.push_str(&format!(
        "<header><h1>🛰️ {year} · 微信年度报告</h1><p class=\"sub\">由 WeChatExporter 本地生成 · 共 {total} 条消息 · 生成于 {}</p></header>",
        util::now_local_hm()
    ));

    // 概览卡
    html.push_str("<section class=\"cards\">");
    html.push_str(&format!(
        "<div class=\"card\"><div class=\"num\">{session_count}</div><div>会话数</div></div>"
    ));
    html.push_str(&format!(
        "<div class=\"card\"><div class=\"num\">{total}</div><div>消息总数</div></div>"
    ));
    html.push_str("<div class=\"card\"><div class=\"num\">0</div><div>媒体总数</div></div>");
    html.push_str(&format!(
        "<div class=\"card\"><div class=\"num\">{}</div><div>活跃天数</div></div>",
        active_days.len()
    ));
    html.push_str(&format!(
        "<div class=\"card\"><div class=\"num\">{}</div><div>峰值月份</div></div>",
        peak_month.as_deref().unwrap_or("—")
    ));
    html.push_str("</section>");

    // 月度消息量
    html.push_str("<section><h2>月度消息量</h2>");
    if !month_counts.is_empty() {
        let mut months: Vec<String> = month_counts.keys().cloned().collect();
        months.sort();
        let maxm = month_counts.values().copied().max().unwrap_or(1).max(1);
        for m in months {
            let c = month_counts[&m];
            let w = (c as f64 / maxm as f64 * 100.0).round().max(2.0) as usize;
            let trophy = if peak_month.as_deref() == Some(m.as_str()) {
                " 🏆"
            } else {
                ""
            };
            html.push_str(&format!(
                "<div class=\"bar-row\"><span class=\"bar-label\">{}{trophy}</span><div class=\"bar-track\"><div class=\"bar\" style=\"width:{w}%\"></div></div><span class=\"bar-value\">{c}</span></div>",
                crate::core::models::escape_html(&m)
            ));
        }
    } else {
        html.push_str("<p class=\"sub\">无时间数据</p>");
    }
    html.push_str("</section>");

    // 词频 top30
    html.push_str("<section><h2>高频词 Top 30</h2>");
    if !top_words.is_empty() {
        let maxw = top_words[0].1.max(1);
        for (w, c) in &top_words {
            let pct = (c * 100 / maxw).max(2);
            html.push_str(&format!(
                "<div class=\"bar-row\"><span class=\"bar-label\">{}</span><div class=\"bar-track\"><div class=\"bar bar-purple\" style=\"width:{pct}%\"></div></div><span class=\"bar-value\">{c}</span></div>",
                crate::core::models::escape_html(w)
            ));
        }
    } else {
        html.push_str("<p class=\"sub\">无文本数据</p>");
    }
    html.push_str("</section>");

    // 发言排行 top10
    html.push_str("<section><h2>跨会话发言排行 Top 10</h2>");
    if !top_senders.is_empty() {
        let maxs = top_senders[0].1.max(1);
        for (name, c) in &top_senders {
            let pct = (c * 100 / maxs).max(2);
            html.push_str(&format!(
                "<div class=\"bar-row\"><span class=\"bar-label\">{}</span><div class=\"bar-track\"><div class=\"bar\" style=\"width:{pct}%\"></div></div><span class=\"bar-value\">{c}</span></div>",
                crate::core::models::escape_html(name)
            ));
        }
    } else {
        html.push_str("<p class=\"sub\">无发言数据</p>");
    }
    html.push_str("</section>");

    // 24 小时分布
    html.push_str("<section><h2>24 小时活跃分布</h2><div class=\"hours\">");
    let maxh = hour_counts.values().copied().max().unwrap_or(1).max(1);
    for h in 0..24 {
        let c = hour_counts.get(&h).copied().unwrap_or(0);
        let ph = (c as f64 / maxh as f64 * 100.0).round() as usize;
        html.push_str(&format!(
            "<div class=\"hour-cell\"><div class=\"hour-bar\" style=\"height:{ph}%\" title=\"{c} 条\"></div><span>{h}时</span></div>"
        ));
    }
    html.push_str("</div></section>");

    html.push_str(&format!(
        "<footer>© {} · WeChatExporter 本地生成 · 数据未离开你的设备{}</footer></body></html>",
        crate::core::watermark::html_escape(if wm.active() {
            &wm.text
        } else {
            "WeChatExporter"
        }),
        wm.html_footer()
    ));

    let out = export_root.join(format!("年度报告_{year}.html"));
    std::fs::write(&out, html).map_err(|e| crate::core::err(format!("写年度报告失败：{e}")))?;
    log(format!("年度报告已生成：年度报告_{year}.html"));
    Ok(Some(out))
}

/// 分词：拉丁按单词、CJK 按 bigram，去停用词。返回 (词, 计数增量)
fn tokenize(text: &str) -> Vec<(String, usize)> {
    let mut counts: HashMap<String, usize> = HashMap::new();
    let stop: std::collections::HashSet<&str> = STOPWORDS.iter().copied().collect();

    // 拉丁单词
    for w in text.split(|c: char| !c.is_ascii_alphanumeric()) {
        let w = w.to_lowercase();
        if w.len() >= 2 && !stop.contains(w.as_str()) {
            *counts.entry(w).or_insert(0) += 1;
        }
    }
    // CJK 连续段 bigram
    let cjk_runs: Vec<String> = text
        .split(|c: char| !is_cjk(c))
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect();
    for run in cjk_runs {
        let chars: Vec<char> = run.chars().collect();
        for w in chars.windows(2) {
            let bigram: String = w.iter().collect();
            let single_is_stop = bigram
                .chars()
                .all(|c| stop.contains(c.to_string().as_str()));
            if !single_is_stop {
                *counts.entry(bigram).or_insert(0) += 1;
            }
        }
    }
    counts.into_iter().collect()
}

fn is_cjk(c: char) -> bool {
    matches!(c as u32, 0x4E00..=0x9FFF | 0x3400..=0x4DBF | 0x20000..=0x2A6DF)
}

const STYLES: &str = r#"
    :root { --bg:#0b1026; --card:rgba(255,255,255,0.05); --cyan:#00f5ff; --purple:#7b61ff; --text:#f0f8ff; --sub:#9aa7c7; }
    * { box-sizing:border-box; }
    body { margin:0; padding:32px 16px; background:radial-gradient(1200px 600px at 50% -100px,#1b2a5e 0%,var(--bg) 60%); color:var(--text); font-family:-apple-system,"PingFang SC","Microsoft YaHei","Noto Sans CJK SC",sans-serif; }
    header, section { max-width:860px; margin:0 auto; }
    header { text-align:center; margin-bottom:28px; }
    h1 { font-size:28px; margin:0 0 8px; background:linear-gradient(92deg,var(--cyan),var(--purple)); -webkit-background-clip:text; background-clip:text; color:transparent; }
    .sub { color:var(--sub); font-size:13px; }
    .cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:12px; margin-bottom:28px; }
    .card { background:var(--card); border:1px solid rgba(0,245,255,0.18); border-radius:14px; padding:18px; text-align:center; }
    .card .num { font-size:26px; font-weight:700; color:var(--cyan); }
    section { background:var(--card); border:1px solid rgba(0,245,255,0.14); border-radius:14px; padding:20px; margin-bottom:20px; }
    h2 { font-size:17px; margin:0 0 14px; color:var(--cyan); }
    .bar-row { display:flex; align-items:center; gap:10px; margin:8px 0; font-size:13px; }
    .bar-label { width:120px; text-align:right; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .bar-track { flex:1; height:14px; background:rgba(255,255,255,0.07); border-radius:7px; overflow:hidden; }
    .bar { height:100%; background:linear-gradient(90deg,var(--cyan),var(--purple)); border-radius:7px; }
    .bar-purple { background:linear-gradient(90deg,var(--purple),#ff4dd2); }
    .bar-value { width:60px; color:var(--sub); }
    .hours { display:grid; grid-template-columns:repeat(12,1fr); gap:6px; }
    .hour-cell { text-align:center; font-size:11px; color:var(--sub); }
    .hour-bar { margin:0 auto 4px; width:70%; min-height:3px; height:60px; display:flex; align-items:flex-end; background:linear-gradient(180deg,var(--cyan),var(--purple)); border-radius:4px 4px 0 0; }
    footer { text-align:center; color:var(--sub); font-size:12px; margin-top:24px; }
"#;
