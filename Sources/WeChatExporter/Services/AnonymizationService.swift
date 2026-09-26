import Foundation

/// 脱敏导出（SPEC §3）：把导出目录文本产物中的真实名称替换为 用户A/B/… 代号，
/// 可选 PII 模糊化（手机号 138****5678 / 身份证保头6尾2 / 邮箱保首字符+***@域名）。
/// 映射写入 anonymization-map.json；keepMapping=false 时调用方在导出完成后删除该文件。
enum AnonymizationService {
    static let mapFileName = "anonymization-map.json"
    static let textExtensions: Set<String> = ["txt", "csv", "json", "html", "epub"]

    struct Settings {
        var maskPii = true
        var keepMapping = true
    }

    struct MappingFile: Codable {
        let version: Int
        let generatedAt: String
        let nameMap: [String: String]
        let note: String
    }

    /// 对目录下全部文本产物做脱敏。返回替换表（原名→代号）。
    @discardableResult
    static func anonymize(
        in base: URL,
        names: [String],
        settings: Settings,
        log: @escaping (String) -> Void
    ) -> [String: String] {
        // 1) 确定性代号：按名称排序分配 A-Z，超 26 转 AA-AB…
        let sorted = Array(Set(names.filter { !$0.isEmpty })).sorted()
        var nameMap: [String: String] = [:]
        for (i, name) in sorted.enumerated() {
            nameMap[name] = "用户\(code(at: i))"
        }

        var replaced = 0
        var filesTouched = 0
        let fm = FileManager.default
        guard let en = fm.enumerator(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            log("脱敏失败：无法遍历导出目录")
            return nameMap
        }
        for case let url as URL in en {
            let ext = url.pathExtension.lowercased()
            guard Self.textExtensions.contains(ext) else { continue }
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let before = text.count
            // 先 PII（避免与名称替换互相干扰）
            if settings.maskPii {
                text = maskPhone(text)
                text = maskIDCard(text)
                text = maskEmail(text)
            }
            // 名称替换：长名优先（防止「林琝淏科技」被「林琝淏」先替换掉）
            for (original, alias) in nameMap.sorted(by: { $0.key.count > $1.key.count }) {
                text = text.replacingOccurrences(of: original, with: alias)
            }
            if text.count != before || text != (try? String(contentsOf: url, encoding: .utf8)) {
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    filesTouched += 1
                } catch {
                    log("脱敏写入失败：\(url.lastPathComponent)")
                }
            }
            replaced += 1
        }

        // 写映射文件
        let mapURL = base.appendingPathComponent(mapFileName)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let payload = MappingFile(
            version: 1,
            generatedAt: f.string(from: Date()),
            nameMap: nameMap,
            note: "删除此文件即不可逆；代号按名称排序确定性分配"
        )
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: mapURL)
        } catch {
            log("映射文件写入失败：\(error.localizedDescription)")
        }
        if !settings.keepMapping {
            try? fm.removeItem(at: mapURL)
        }

        log("脱敏完成：\(filesTouched) 个文件（\(replaced) 个文本产物扫描），代号 \(nameMap.count) 个"
            + (settings.maskPii ? "，PII 已模糊化" : "")
            + (settings.keepMapping ? "，映射文件已保留（可逆）" : "，映射已销毁（不可逆）"))
        return nameMap
    }

    // MARK: - PII 模糊化（正则）

    private static func maskPhone(_ s: String) -> String {
        let pattern = "(?<!\\d)(1[3-9]\\d)(\\d{4})(\\d{4})(?!\\d)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return replaceMatches(re, in: s) { m, s in
            guard m.numberOfRanges == 4 else { return "" }
            return "\(sub(s, m.range(at: 1)))****\(sub(s, m.range(at: 3)))"
        }
    }

    private static func maskIDCard(_ s: String) -> String {
        let pattern = "(?<!\\d)(\\d{6})\\d{8}(\\d{3}[\\dXx])(?!\\d)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return replaceMatches(re, in: s) { m, s in
            guard m.numberOfRanges == 3 else { return "" }
            return sub(s, m.range(at: 1)) + String(repeating: "*", count: 8) + sub(s, m.range(at: 2))
        }
    }

    private static func maskEmail(_ s: String) -> String {
        let pattern = "([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9.-]+)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return replaceMatches(re, in: s) { m, s in
            guard m.numberOfRanges == 3 else { return "" }
            return "\(sub(s, m.range(at: 1)))***@\(sub(s, m.range(at: 2)))"
        }
    }

    /// 手动拼接式替换（避开 stringByReplacingMatches 的模板/评估器重载歧义）。
    /// 全程用 NSString（UTF-16）做区间拼接，与 NSRange 语义一致，中英文都正确。
    private static func replaceMatches(
        _ re: NSRegularExpression,
        in s: String,
        _ body: (NSTextCheckingResult, String) -> String
    ) -> String {
        let ns = s as NSString
        let matches = re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var result = ""
        var lastEnd = 0
        for m in matches {
            let r = m.range
            guard r.location >= lastEnd else { continue }
            result += ns.substring(with: NSRange(location: lastEnd, length: r.location - lastEnd))
            result += body(m, s)
            lastEnd = r.location + r.length
        }
        if lastEnd < ns.length {
            result += ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))
        }
        return result
    }

    /// 取字符串在 UTF-16 区间 [range] 的子串（NSString 语义）。
    private static func sub(_ s: String, _ range: NSRange) -> String {
        let ns = s as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return "" }
        return ns.substring(with: range)
    }

    /// 代号序列：0→A … 25→Z，26→AA …
    private static func code(at index: Int) -> String {
        var n = index
        var out = ""
        while true {
            out = String(UnicodeScalar(UInt8(65 + n % 26))) + out
            n /= 26
            if n == 0 { break }
            n -= 1
        }
        return out
    }

    // MARK: - 收集目录中出现的名称（从 chat.json 的 sender 字段）

    /// 扫描 base 下所有 chat.json，收集去重后的 sender 名称集合。
    static func collectNames(in base: URL) -> Set<String> {
        var names = Set<String>()
        let fm = FileManager.default
        guard let en = fm.enumerator(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return names
        }
        for case let url as URL in en where url.lastPathComponent == "chat.json" {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) else { continue }
            let rows: [[String: Any]]
            if let arr = root as? [[String: Any]] {
                rows = arr
            } else if let dict = root as? [String: Any] {
                rows = (dict["items"] as? [[String: Any]])
                    ?? (dict["messages"] as? [[String: Any]])
                    ?? (dict["results"] as? [[String: Any]])
                    ?? []
            } else {
                continue
            }
            for row in rows {
                let nested = row["message"] as? [String: Any]
                let src = nested ?? row
                if let s = src["sender"] as? String, !s.isEmpty, s != "系统", s != "未知" {
                    names.insert(s)
                }
            }
            // 会话目录名本身也是名称（单文件 HTML 标题里会出现）
            names.insert(url.deletingLastPathComponent().lastPathComponent)
        }
        return names
    }
}
