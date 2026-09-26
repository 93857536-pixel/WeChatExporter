//! 日历提取（SPEC §6）：从消息文本启发式提取事件，生成 `日历事件.json` + `日历事件.ics`

use crate::core::models::Message;
use crate::core::util;
use chrono::Datelike;
use md5::Digest;
use crate::core::Result;
use serde::Serialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize)]
pub struct CalendarEvent {
    pub session: String,
    pub message_ts: i64,
    pub summary: String,
    pub start: String,
    pub end: String,
    pub raw: String,
}

pub fn write_events(
    export_root: &Path,
    log: &mut dyn FnMut(String),
) -> Result<Option<(usize, PathBuf, PathBuf)>> {
    let mut events: Vec<CalendarEvent> = Vec::new();
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
            let session = e.file_name().to_string_lossy().into_owned();
            if let Ok(data) = std::fs::read_to_string(&json) {
                if let Ok(msgs) = serde_json::from_str::<Vec<Message>>(&data) {
                    for msg in msgs {
                        if let Some(ev) = extract_event(&session, &msg) {
                            events.push(ev);
                        }
                    }
                }
            }
        }
    }
    if events.is_empty() {
        return Ok(None);
    }

    let json_path = export_root.join("日历事件.json");
    let json = serde_json::to_string_pretty(&events)
        .map_err(|e| crate::core::err(format!("序列化日历失败：{e}")))?;
    std::fs::write(&json_path, json)
        .map_err(|e| crate::core::err(format!("写日历 json 失败：{e}")))?;

    let ics_path = export_root.join("日历事件.ics");
    let ics = render_ics(&events);
    std::fs::write(&ics_path, ics)
        .map_err(|e| crate::core::err(format!("写日历 ics 失败：{e}")))?;

    let n = events.len();
    log(format!("日历事件 {n} 条"));
    Ok(Some((n, json_path, ics_path)))
}

/// 启发式提取单条事件；无匹配返回 None
fn extract_event(session: &str, msg: &Message) -> Option<CalendarEvent> {
    let text = msg.content.trim();
    if text.is_empty() || text.len() > 200 {
        return None;
    }

    // 相对：明天 / 后天 / 大后天
    let msg_date = util::format_date(msg.timestamp);
    let base_date = chrono::NaiveDate::parse_from_str(&msg_date, "%Y-%m-%d").ok()?;
    let (date_str, matched_date) = if let Some((days, _)) = find_relative_day(text) {
        let d = base_date.checked_add_days(chrono::Days::new(days))?;
        (d.format("%Y-%m-%d").to_string(), true)
    } else if let Some(d) = find_absolute_date(text, base_date) {
        (d.format("%Y-%m-%d").to_string(), true)
    } else {
        return None;
    };
    let _ = matched_date;

    let (hour, minute) = find_time(text);
    let start = format!("{date_str} {:02}:{:02}", hour, minute);
    let end = format!("{date_str} {:02}:{:02}", hour + 1, minute);

    let summary: String = text.chars().take(60).collect();
    Some(CalendarEvent {
        session: session.to_string(),
        message_ts: msg.timestamp,
        summary,
        start,
        end,
        raw: text.to_string(),
    })
}

/// 明天=1 / 后天=2 / 大后天=3，返回 (天数, 匹配标记)
fn find_relative_day(text: &str) -> Option<(u64, &'static str)> {
    if text.contains("大后天") {
        Some((3, "大后天"))
    } else if text.contains("后天") {
        Some((2, "后天"))
    } else if text.contains("明天") {
        Some((1, "明天"))
    } else {
        None
    }
}

/// 绝对日期：YYYY-MM-DD / YYYY/MM/DD / M月D日（默认当年；若 < 消息月份则 +1 年）
fn find_absolute_date(text: &str, msg_date: chrono::NaiveDate) -> Option<chrono::NaiveDate> {
    // YYYY-MM-DD
    for (idx, _) in text.match_indices(|c: char| c.is_ascii_digit()) {
        if let Some(d) = try_parse_iso(&text[idx..]) {
            return Some(d);
        }
    }
    // M月D日 / M月D号
    if let Some(d) = try_parse_cn_date(text, msg_date) {
        return Some(d);
    }
    None
}

fn try_parse_iso(s: &str) -> Option<chrono::NaiveDate> {
    let chars: Vec<char> = s.chars().collect();
    if chars.len() < 8 {
        return None;
    }
    // 期望 YYYY-MM-DD（也接受 YYYY/MM/DD、YYYY.MM.DD，月/日不足两位补 0）
    let y: String = chars[0..4].iter().collect();
    if !y.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let sep = chars[4];
    if sep != '-' && sep != '/' && sep != '.' {
        return None;
    }
    let m_digits: String = chars[5..]
        .iter()
        .take_while(|c| c.is_ascii_digit())
        .take(2)
        .collect();
    if m_digits.is_empty() {
        return None;
    }
    let m_end = 5 + m_digits.len();
    if m_end >= chars.len() || chars[m_end] != sep {
        return None;
    }
    let d_start = m_end + 1;
    if d_start >= chars.len() {
        return None;
    }
    let d_digits: String = chars[d_start..]
        .iter()
        .take_while(|c| c.is_ascii_digit())
        .take(2)
        .collect();
    if d_digits.is_empty() {
        return None;
    }
    let y: i32 = y.parse().ok()?;
    let m: u32 = m_digits.parse().ok()?;
    let d: u32 = d_digits.parse().ok()?;
    chrono::NaiveDate::from_ymd_opt(y, m, d)
}

fn try_parse_cn_date(text: &str, msg_date: chrono::NaiveDate) -> Option<chrono::NaiveDate> {
    let bytes: Vec<char> = text.chars().collect();
    for i in 0..bytes.len() {
        if bytes[i].is_ascii_digit() {
            // 读数字
            let mut j = i;
            let mut num = String::new();
            while j < bytes.len() && bytes[j].is_ascii_digit() {
                num.push(bytes[j]);
                j += 1;
            }
            if j >= bytes.len() || (bytes[j] != '月') {
                continue;
            }
            let month: u32 = num.parse().ok()?;
            // 月 后是 日/号
            let mut k = j + 1;
            let mut day = String::new();
            while k < bytes.len() && bytes[k].is_ascii_digit() {
                day.push(bytes[k]);
                k += 1;
            }
            if k >= bytes.len() || (bytes[k] != '日' && bytes[k] != '号') {
                continue;
            }
            let day: u32 = day.parse().ok()?;
            let mut year = msg_date.year();
            if (month as u32) < msg_date.month() {
                year += 1;
            }
            return chrono::NaiveDate::from_ymd_opt(year, month, day);
        }
    }
    None
}

/// 时间：上午/早上 N点 → N 点；下午 N点 → N+12；晚上 N点 → N+12；裸 N点按字面
fn find_time(text: &str) -> (u32, u32) {
    let bytes: Vec<char> = text.chars().collect();
    for i in 0..bytes.len() {
        if bytes[i].is_ascii_digit() {
            let mut j = i;
            let mut num = String::new();
            while j < bytes.len() && bytes[j].is_ascii_digit() {
                num.push(bytes[j]);
                j += 1;
            }
            // 后面紧跟「点」或「:」
            let is_point = j < bytes.len() && bytes[j] == '点';
            let is_colon = j < bytes.len() && bytes[j] == ':';
            if !is_point && !is_colon {
                continue;
            }
            let n: u32 = num.parse().unwrap_or(0);
            // 冒号形式 N:MM
            if is_colon {
                let mut k = j + 1;
                let mut min = String::new();
                while k < bytes.len() && bytes[k].is_ascii_digit() {
                    min.push(bytes[k]);
                    k += 1;
                }
                let minute: u32 = min.parse().unwrap_or(0);
                return (n % 24, minute % 60);
            }
            // 点 形式：看前面修饰词（char 前缀判断，避免字节边界 panic）
            let prefix: String = bytes[..i].iter().collect();
            let pm = prefix.contains("下午") || prefix.contains("晚上");
            let hour = if pm {
                if n < 12 {
                    n + 12
                } else {
                    n
                }
            } else {
                n
            };
            return (hour % 24, 0);
        }
    }
    (9, 0)
}

fn render_ics(events: &[CalendarEvent]) -> String {
    use std::fmt::Write;
    let mut out = String::new();
    out.push_str("BEGIN:VCALENDAR\r\n");
    out.push_str("VERSION:2.0\r\n");
    out.push_str("PRODID:-//WeChatExporter//CN\r\n");
    out.push_str("CALSCALE:GREGORIAN\r\n");
    out.push_str("X-WR-TIMEZONE:Asia/Shanghai\r\n");
    let dtstamp = util::now_utc_iso().replace('Z', "");
    for ev in events {
        let uid = format!(
            "{:x}",
            md5::Md5::digest(format!("{}|{}|{}", ev.session, ev.message_ts, ev.start).as_bytes())
        );
        let summary = format!("[{}] {}", ev.session, ev.summary);
        let start = ev.start.replace(' ', "T");
        let end = ev.end.replace(' ', "T");
        writeln!(out, "BEGIN:VEVENT").unwrap();
        writeln!(out, "UID:{uid}@wce").unwrap();
        writeln!(out, "DTSTAMP:{dtstamp}").unwrap();
        writeln!(out, "DTSTART;TZID=Asia/Shanghai:{start}").unwrap();
        writeln!(out, "DTEND;TZID=Asia/Shanghai:{end}").unwrap();
        writeln!(out, "SUMMARY:{}", ics_escape(&summary)).unwrap();
        writeln!(out, "END:VEVENT").unwrap();
    }
    out.push_str("END:VCALENDAR\r\n");
    out
}

fn ics_escape(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace(';', "\\;")
        .replace(',', "\\,")
        .replace('\n', "\\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn msg(ts: i64, content: &str) -> Message {
        Message {
            time: "t".into(),
            timestamp: ts,
            sender: "a".into(),
            msg_type: 1,
            type_name: "文本".into(),
            content: content.into(),
        }
    }

    #[test]
    fn absolute_date_and_time() {
        // 2024-01-10 08:00 上海 = 1704844800
        let m = msg(1_704_844_800, "2024-03-15 下午3点开会");
        let ev = extract_event("测试", &m).unwrap();
        assert_eq!(ev.start, "2024-03-15 15:00");
        assert_eq!(ev.end, "2024-03-15 16:00");
    }

    #[test]
    fn relative_tomorrow() {
        let m = msg(1_704_844_800, "明天上午9点见"); // 2024-01-10
        let ev = extract_event("测试", &m).unwrap();
        assert_eq!(ev.start, "2024-01-11 09:00");
    }

    #[test]
    fn ics_header() {
        let ics = render_ics(&[]);
        assert!(ics.starts_with("BEGIN:VCALENDAR\r\n"));
        assert!(ics.contains("X-WR-TIMEZONE:Asia/Shanghai"));
    }
}
