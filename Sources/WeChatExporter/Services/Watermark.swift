import Foundation

/// 导出水印（双端对称实现，Windows 见 Services/Watermark.cs）。
/// 水印文字默认「林琝淏科技集团有限公司」，可在设置中修改；开关默认开启（关闭即无水印版本）。
struct Watermark {
    var enabled: Bool
    var text: String

    /// 实际是否生效（开关开且文字非空）
    var active: Bool {
        enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 当前设置（macOS 读取 UserDefaults 持久化偏好）
    static var current: Watermark {
        Watermark(
            enabled: ExportModePreferences.watermarkEnabled,
            text: ExportModePreferences.watermarkText
        )
    }

    /// HTML 视觉水印层：固定全屏平铺斜纹文字（CSS SVG data URI，零依赖，离线可渲染）。
    /// - Parameter lightBackground: 产物背景为浅色（打印版 HTML / 文档）时用深色水印。
    static func htmlOverlay(lightBackground: Bool = false) -> String {
        let wm = Self.current
        guard wm.active else { return "" }
        let fill = lightBackground ? "rgba(0,0,0,0.10)" : "rgba(255,255,255,0.14)"
        let uri = svgDataURI(text: wm.text, fill: fill)
        return "<div class=\"wm-overlay\" aria-hidden=\"true\"></div>"
            + "<style>.wm-overlay{position:fixed;inset:0;z-index:2147483000;pointer-events:none;background-repeat:repeat;background-image:url(\"data:image/svg+xml;charset=utf-8,\(uri)\");}</style>"
    }

    /// HTML 页脚版权行（追加在文档 footer / 末尾）
    static func htmlFooter() -> String {
        let wm = Self.current
        guard wm.active else { return "" }
        return "<p class=\"wm-footer\" style=\"text-align:center;opacity:.7;font-size:12px;margin:16px 0 0\">© \(htmlEscape(wm.text))</p>"
    }

    /// 纯文本版权行（EPUB / PDF 等文档产物）
    static func plainLine() -> String {
        let wm = Self.current
        guard wm.active else { return "" }
        return "© \(wm.text)"
    }

    /// 幂等后处理：扫描目录内全部 `*.html`，缺水印层的注入 overlay + 页脚版权行。
    /// 已含水印层的文件跳过（可重复执行）。用于兜底任何直出 HTML 的生成路径。
    @discardableResult
    static func applyToDirectory(_ dir: URL, log: @escaping (String) -> Void) -> Int {
        let wm = Self.current
        guard wm.active else { return 0 }
        let fm = FileManager.default
        var count = 0
        if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let f as URL in enumerator where f.pathExtension.lowercased() == "html" {
                guard let raw = try? String(contentsOf: f, encoding: .utf8) else { continue }
                guard !raw.contains("wm-overlay") else { continue }
                let bodyTag = raw.range(of: "<body")?.upperBound ?? raw.startIndex
                var patched = raw
                patched.insert(contentsOf: Watermark.htmlOverlay(), at: bodyTag)
                if let close = patched.range(of: "</body>") {
                    patched.insert(contentsOf: Watermark.htmlFooter(), at: close.lowerBound)
                }
                if (try? patched.write(to: f, atomically: true, encoding: .utf8)) != nil {
                    count += 1
                }
            }
        }
        if count > 0 { log("已为 \(count) 份 HTML 注入水印") }
        return count
    }

    /// 水印 SVG 的 data URI（UTF-8 字节逐字节 percent-encode，ASCII 安全字符原样保留）。
    /// 用 `charset=utf-8` + 全量百分号编码，浏览器离线可解析。
    static func svgDataURI(text: String, fill: String) -> String {
        let t = htmlEscape(text)
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='300' height='180'>"
            + "<text x='150' y='90' font-size='20' font-family='-apple-system, PingFang SC, Microsoft YaHei, sans-serif'"
            + " fill='\(fill)' text-anchor='middle' dominant-baseline='middle'"
            + " transform='rotate(-18 150 90)'>\(t)</text></svg>"
        guard let data = svg.data(using: .utf8) else { return "" }
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~'():".utf8)
        var out = ""
        out.reserveCapacity(data.count * 3)
        for b in data {
            if safe.contains(b) {
                out += String(UnicodeScalar(b))
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    /// HTML 转义
    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
