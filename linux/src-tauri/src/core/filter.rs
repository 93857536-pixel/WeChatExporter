//! 过滤导出（SPEC §4）：按日期区间 + 关键词过滤消息

use crate::core::models::Message;
use crate::core::util;

/// 解析过滤关键词（逗号分隔，去空白）
pub fn parse_keywords(keywords: &str) -> Vec<String> {
    keywords
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// 过滤起止时间戳（含首尾）：from = 起始日 00:00:00，to = 结束日 23:59:59（Asia/Shanghai）
pub fn date_range_ts(from_date: &str, to_date: &str) -> (Option<i64>, Option<i64>) {
    let from = util::parse_date_local(from_date);
    let to = util::parse_date_local(to_date).map(|t| t + 86399);
    (from, to)
}

/// 按条件过滤消息（区间含首尾，关键词不区分大小写；keywords 为空=不过滤内容）
pub fn filter_messages(
    messages: &[Message],
    from: Option<i64>,
    to: Option<i64>,
    keywords: &[String],
) -> Vec<Message> {
    messages
        .iter()
        .filter(|m| {
            if let Some(f) = from {
                if m.timestamp < f {
                    return false;
                }
            }
            if let Some(t) = to {
                if m.timestamp > t {
                    return false;
                }
            }
            if !keywords.is_empty() {
                let content_lower = m.content.to_lowercase();
                if !keywords
                    .iter()
                    .any(|k| content_lower.contains(&k.to_lowercase()))
                {
                    return false;
                }
            }
            true
        })
        .cloned()
        .collect()
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
    fn filter_by_keyword_case_insensitive() {
        let msgs = vec![
            msg(1, "Hello World"),
            msg(2, "goodbye"),
            msg(3, "HELLO again"),
        ];
        let out = filter_messages(&msgs, None, None, &vec!["hello".to_string()]);
        assert_eq!(out.len(), 2);
    }

    #[test]
    fn filter_by_range() {
        let (from, to) = date_range_ts("2024-01-01", "2024-01-01");
        let msgs = vec![msg(1_704_067_200, "x"), msg(1_704_153_600, "x")]; // 2024-01-01 08:00 与 2024-01-02
        let out = filter_messages(&msgs, from, to, &[]);
        assert_eq!(out.len(), 1);
    }
}
