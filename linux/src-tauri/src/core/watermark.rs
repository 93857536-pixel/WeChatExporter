//! 导出水印（与 macOS `Services/Watermark.swift` / Windows `Watermark.cs` 对称实现）
//! 水印文字默认「林琝淏科技集团有限公司」，可在设置中修改；开关默认开启。

pub const DEFAULT_WATERMARK_TEXT: &str = "林琝淏科技集团有限公司";

#[derive(Debug, Clone)]
pub struct Watermark {
    pub enabled: bool,
    pub text: String,
}

impl Default for Watermark {
    fn default() -> Self {
        Watermark {
            enabled: true,
            text: DEFAULT_WATERMARK_TEXT.to_string(),
        }
    }
}

impl Watermark {
    /// 实际是否生效（开关开且文字非空）
    pub fn active(&self) -> bool {
        self.enabled && !self.text.trim().is_empty()
    }

    /// HTML 视觉水印层：固定全屏平铺斜纹文字（CSS SVG data URI，零依赖，离线可渲染）
    pub fn html_overlay(&self, light_background: bool) -> String {
        if !self.active() {
            return String::new();
        }
        let fill = if light_background {
            "rgba(0,0,0,0.10)"
        } else {
            "rgba(255,255,255,0.14)"
        };
        let uri = self.svg_data_uri(&self.text, fill);
        format!(
            "<div class=\"wm-overlay\" aria-hidden=\"true\"></div>\
             <style>.wm-overlay{{position:fixed;inset:0;z-index:2147483000;pointer-events:none;background-repeat:repeat;background-image:url(\"data:image/svg+xml;charset=utf-8,{uri}\");}}</style>"
        )
    }

    /// HTML 页脚版权行
    pub fn html_footer(&self) -> String {
        if !self.active() {
            return String::new();
        }
        format!(
            "<p class=\"wm-footer\" style=\"text-align:center;opacity:.7;font-size:12px;margin:16px 0 0\">© {}</p>",
            html_escape(&self.text)
        )
    }

    /// 纯文本版权行（EPUB / 文档产物）
    pub fn plain_line(&self) -> String {
        if !self.active() {
            return String::new();
        }
        format!("© {}", self.text)
    }

    /// 幂等后处理：扫描目录内全部 `*.html`，缺水印层的注入 overlay + 页脚版权行。
    /// 返回注入的文件数。
    pub fn apply_to_directory(&self, dir: &std::path::Path, log: &mut dyn FnMut(String)) -> usize {
        if !self.active() {
            return 0;
        }
        let mut count = 0;
        let entries = match std::fs::read_dir(dir) {
            Ok(e) => e,
            Err(_) => return 0,
        };
        let mut html_files: Vec<std::path::PathBuf> = entries
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.is_file() && p.extension().map(|e| e == "html").unwrap_or(false))
            .collect();
        // 递归一层子目录（会话目录）
        if let Ok(entries) = std::fs::read_dir(dir) {
            for e in entries.filter_map(|e| e.ok()) {
                let p = e.path();
                if p.is_dir() {
                    if let Ok(sub) = std::fs::read_dir(&p) {
                        for se in sub.filter_map(|s| s.ok()) {
                            let sp = se.path();
                            if sp.is_file() && sp.extension().map(|x| x == "html").unwrap_or(false)
                            {
                                html_files.push(sp);
                            }
                        }
                    }
                }
            }
        }
        html_files.sort();
        for f in html_files {
            let raw = match std::fs::read_to_string(&f) {
                Ok(r) => r,
                Err(_) => continue,
            };
            if raw.contains("wm-overlay") {
                continue;
            }
            let mut patched = raw.clone();
            if let Some(idx) = raw.find("<body") {
                let insert_at = raw[idx..].find('>').map(|o| idx + o + 1).unwrap_or(idx + 5);
                patched.insert_str(insert_at, &self.html_overlay(false));
            }
            if let Some(close) = patched.rfind("</body>") {
                patched.insert_str(close, &self.html_footer());
            }
            if std::fs::write(&f, patched).is_ok() {
                count += 1;
            }
        }
        if count > 0 {
            log(format!("已为 {count} 份 HTML 注入水印"));
        }
        count
    }

    /// 水印 SVG 的 data URI（UTF-8 字节逐字节 percent-encode，ASCII 安全字符原样保留）
    pub fn svg_data_uri(&self, text: &str, fill: &str) -> String {
        let t = html_escape(text);
        let svg = format!(
            "<svg xmlns='http://www.w3.org/2000/svg' width='300' height='180'>\
             <text x='150' y='90' font-size='20' font-family='-apple-system, PingFang SC, Microsoft YaHei, sans-serif' \
             fill='{fill}' text-anchor='middle' dominant-baseline='middle' \
             transform='rotate(-18 150 90)'>{t}</text></svg>"
        );
        percent_encode_utf8(&svg)
    }
}

/// HTML 转义（& < >）
pub fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// UTF-8 字节逐字节 percent-encode，ASCII 安全字符原样保留（与 Swift 端一致）
pub fn percent_encode_utf8(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(bytes.len());
    for &b in bytes {
        let c = b as char;
        if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '~' | '\'' | '(' | ')' | ':')
        {
            out.push(c);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percent_encode_chinese() {
        // "中" UTF-8 = E4 B8 AD
        assert_eq!(percent_encode_utf8("中"), "%E4%B8%AD");
        assert_eq!(percent_encode_utf8("abc"), "abc");
    }

    #[test]
    fn watermark_inactive_when_disabled() {
        let wm = Watermark {
            enabled: false,
            text: "x".into(),
        };
        assert!(!wm.active());
        assert!(wm.html_overlay(false).is_empty());
    }

    #[test]
    fn overlay_contains_class() {
        let wm = Watermark::default();
        assert!(wm.html_overlay(false).contains("wm-overlay"));
    }
}
