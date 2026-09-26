//! 时间与常用工具（Asia/Shanghai 固定 +8，无夏令时）

use chrono::{DateTime, FixedOffset, Local, SecondsFormat, Timelike, TimeZone, Utc};

pub const SHANGHAI_OFFSET_SECS: i32 = 8 * 3600;

pub fn shanghai_offset() -> FixedOffset {
    FixedOffset::east_opt(SHANGHAI_OFFSET_SECS).expect("valid +8 offset")
}

/// Unix 秒（10 位）→ `yyyy-MM-dd HH:mm:ss`（Asia/Shanghai）
pub fn format_time(ts: i64) -> String {
    if ts <= 0 {
        return String::new();
    }
    // 兼容 13 位毫秒时间戳
    let seconds = if ts > 100_000_000_000 {
        ts / 1000
    } else {
        ts
    };
    match shanghai_offset().timestamp_opt(seconds, 0) {
        chrono::LocalResult::Single(dt) => dt.format("%Y-%m-%d %H:%M:%S").to_string(),
        _ => String::new(),
    }
}

/// Unix 秒 → `yyyy-MM-dd`（Asia/Shanghai）
pub fn format_date(ts: i64) -> String {
    let seconds = if ts > 100_000_000_000 {
        ts / 1000
    } else {
        ts
    };
    match shanghai_offset().timestamp_opt(seconds, 0) {
        chrono::LocalResult::Single(dt) => dt.format("%Y-%m-%d").to_string(),
        _ => String::new(),
    }
}

/// 当前本地时间 `yyyy-MM-dd HH:mm`（生成于… 展示用，跟随系统时区）
pub fn now_local_hm() -> String {
    Local::now().format("%Y-%m-%d %H:%M").to_string()
}

/// 当前本地时间戳 `yyyyMMdd-HHmmss`（文件名用）
pub fn file_stamp() -> String {
    Local::now().format("%Y%m%d-%H%M%S").to_string()
}

/// 当前 UTC ISO8601（.ics DTSTAMP / .wxenc 记录）
pub fn now_utc_iso() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

/// 当前本地 ISO 时间（export.autoSync.lastRun 用）
pub fn now_local_iso() -> String {
    Local::now().to_rfc3339_opts(SecondsFormat::Secs, false)
}

/// `DateTime` → `yyyy-MM`（Asia/Shanghai）
pub fn format_year_month(ts: i64) -> String {
    let seconds = if ts > 100_000_000_000 {
        ts / 1000
    } else {
        ts
    };
    match shanghai_offset().timestamp_opt(seconds, 0) {
        chrono::LocalResult::Single(dt) => dt.format("%Y-%m").to_string(),
        _ => String::new(),
    }
}

/// 取 `ts` 对应的小时（0-23，Asia/Shanghai）
pub fn hour_of(ts: i64) -> Option<u32> {
    let seconds = if ts > 100_000_000_000 {
        ts / 1000
    } else {
        ts
    };
    match shanghai_offset().timestamp_opt(seconds, 0) {
        chrono::LocalResult::Single(dt) => Some(dt.hour()),
        _ => None,
    }
}

/// 字节数 → 人类可读（与 macOS ByteSize.string 同口径）
pub fn byte_size(bytes: u64) -> String {
    let f = bytes as f64;
    if f >= 1_073_741_824.0 {
        format!("{:.1} GB", f / 1_073_741_824.0)
    } else if f >= 1_048_576.0 {
        format!("{:.1} MB", f / 1_048_576.0)
    } else if f >= 1024.0 {
        format!("{:.0} KB", f / 1024.0)
    } else {
        format!("{bytes} B")
    }
}

/// 日期字符串 `yyyy-MM-dd`（本地）解析为 Unix 秒起点（Asia/Shanghai）
pub fn parse_date_local(s: &str) -> Option<i64> {
    let dt = chrono::NaiveDate::parse_from_str(s.trim(), "%Y-%m-%d").ok()?;
    let naive = dt.and_hms_opt(0, 0, 0)?;
    Some(
        shanghai_offset()
            .from_local_datetime(&naive)
            .earliest()?
            .timestamp(),
    )
}

/// 把 `DateTime<Utc>` 转成 Asia/Shanghai 的 `DateTime<FixedOffset>`
pub fn to_shanghai(dt: DateTime<Utc>) -> DateTime<FixedOffset> {
    dt.with_timezone(&shanghai_offset())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_time_shanghai() {
        // 2024-01-01 00:00:00 UTC = 08:00 上海
        assert_eq!(format_time(1_704_067_200), "2024-01-01 08:00:00");
    }

    #[test]
    fn ms_timestamp_normalized() {
        assert_eq!(format_time(1_704_067_200_000), "2024-01-01 08:00:00");
    }

    #[test]
    fn zero_ts_empty() {
        assert_eq!(format_time(0), "");
        assert_eq!(format_time(-1), "");
    }
}
