import Foundation

/// 聊天统计报告：解析导出的 chat.json，聚合消息量/时段/月度趋势/发言排行/媒体构成，
/// 生成单文件 HTML（纯内嵌 CSS + 内联条形图，无外部依赖，可离线打开）。
enum ChatStatsReport {
    /// 从 sourceDir 的 chat.json 生成统计报告 HTML，返回输出文件 URL；无数据返回 nil
    @discardableResult
    static func writeReport(
        from sourceDir: URL,
        contactName: String,
        into destinationDir: URL,
        log: @escaping (String) -> Void
    ) -> URL? {
        let jsonURL = sourceDir.appendingPathComponent("chat.json")
        guard FileManager.default.fileExists(atPath: jsonURL.path),
              let data = try? Data(contentsOf: jsonURL) else {
            log("未找到 chat.json，跳过统计报告")
            return nil
        }
        let rows: [[String: Any]]
        do {
            let root = try JSONSerialization.jsonObject(with: data)
            if let array = root as? [[String: Any]] {
                rows = array
            } else if let dict = root as? [String: Any] {
                rows = (dict["items"] as? [[String: Any]])
                    ?? (dict["messages"] as? [[String: Any]])
                    ?? (dict["results"] as? [[String: Any]])
                    ?? []
            } else {
                rows = []
            }
        } catch {
            log("chat.json 解析失败，跳过统计报告：\(error.localizedDescription)")
            return nil
        }
        guard !rows.isEmpty else {
            log("聊天记录为空，跳过统计报告")
            return nil
        }

        // MARK: 聚合

        var timestamps: [Date] = []
        var senderCounts: [String: Int] = [:]
        var hourBuckets = [Int: Int](minimumCapacity: 24)
        var monthCounts: [String: Int] = [:]
        var monthOrder: [String] = []
        var mediaKinds: [String: Int] = [:]
        var totalMedia = 0

        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone.current
        formatter.dateFormat = "yyyy-MM"

        for row in rows {
            let nested = row["message"] as? [String: Any]
            let source = nested ?? row

            // 时间戳
            let ts = intField(source, keys: ["create_time", "timestamp"])
                ?? intField(row, keys: ["create_time", "timestamp"])
            if let ts, let date = dateFromTimestamp(ts) {
                timestamps.append(date)
            }
            if let date = timestamps.last {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
                let hour = cal.component(.hour, from: date)
                hourBuckets[hour, default: 0] += 1
                let month = formatter.string(from: date)
                if monthCounts[month] == nil { monthOrder.append(month) }
                monthCounts[month, default: 0] += 1
            }

            // 发言人
            let sender = stringField(row, keys: ["sender_display_name", "sender", "from", "display_name"])
                ?? stringField(source, keys: ["sender_display_name", "sender"])
                ?? "未知"
            senderCounts[sender, default: 0] += 1

            // 媒体
            let media = (row["media_files"] as? [String]) ?? (source["media_files"] as? [String]) ?? []
            if !media.isEmpty {
                totalMedia += media.count
                for m in media {
                    let ext = (m as NSString).pathExtension.lowercased()
                    var kind = "其他"
                    switch ext {
                    case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff": kind = "图片"
                    case "silk", "pcm", "wav", "mp3", "m4a", "aac", "amr", "ogg": kind = "语音"
                    case "mp4", "mov", "avi": kind = "视频"
                    default: break
                    }
                    mediaKinds[kind, default: 0] += 1
                }
            }
        }

        let totalMessages = rows.count
        let topSenders = senderCounts.sorted { $0.value > $1.value }.prefix(8)
        let peakMonth = monthCounts.max(by: { $0.value < $1.value })
        let totalChars = rows.reduce(0) { acc, row in
            let nested = row["message"] as? [String: Any]
            let source = nested ?? row
            let text = stringField(row, keys: ["snippet", "content", "text", "message", "summary"])
                ?? stringField(source, keys: ["snippet", "content", "text"]) ?? ""
            return acc + text.count
        }
        let avgLen = totalMessages > 0 ? totalChars / totalMessages : 0
        let earliest = timestamps.min()
        let latest = timestamps.max()

        // MARK: 渲染 HTML

        var html = ""
        html += "<!DOCTYPE html>\n<html lang=\"zh-CN\"><head><meta charset=\"utf-8\">"
        html += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        html += "<title>\(escape(contactName.isEmpty ? "聊天记录统计" : contactName + " 统计"))</title>"
        html += "<style>" + styles + "</style></head><body>"
        html += Watermark.htmlOverlay()
        html += "<header><h1>📊 \(escape(contactName.isEmpty ? "聊天记录" : contactName)) · 统计报告</h1>"
        html += "<p class=\"sub\">数据范围：\(earliest.map { formatDate($0) } ?? "—") 至 \(latest.map { formatDate($0) } ?? "—")　·　共 \(totalMessages) 条消息　·　生成于 \(dateString(Date()))</p></header>"

        // 概览卡片
        html += "<section class=\"cards\"><div class=\"card\"><div class=\"num\">\(totalMessages)</div><div>消息总数</div></div>"
        html += "<div class=\"card\"><div class=\"num\">\(totalMedia)</div><div>媒体附件</div></div>"
        html += "<div class=\"card\"><div class=\"num\">\(topSenders.count)</div><div>参与者</div></div>"
        html += "<div class=\"card\"><div class=\"num\">\(avgLen)</div><div>平均字数/条</div></div></section>"

        // 发言排行
        html += "<section><h2>发言排行</h2>"
        if topSenders.count > 0 {
            let maxCount = topSenders.first?.value ?? 1
            for (name, count) in topSenders {
                let pct = max(3, Int(Double(count) / Double(maxCount) * 100))
                let share = totalMessages > 0 ? String(format: "%.1f%%", Double(count) / Double(totalMessages) * 100) : "0%"
                html += "<div class=\"bar-row\"><span class=\"bar-label\">\(escape(name))</span>"
                html += "<div class=\"bar-track\"><div class=\"bar\" style=\"width:\(pct)%\"></div></div>"
                html += "<span class=\"bar-value\">\(count)（\(share)）</span></div>"
            }
        } else {
            html += "<p class=\"sub\">无发言数据</p>"
        }
        html += "</section>"

        // 时段分布
        html += "<section><h2>24 小时活跃分布</h2><div class=\"hours\">"
        for hour in 0..<24 {
            let count = hourBuckets[hour] ?? 0
            let maxHour = hourBuckets.values.max() ?? 1
            let h = maxHour > 0 ? Int(round(Double(count) / Double(maxHour) * 100)) : 0
            html += "<div class=\"hour-cell\"><div class=\"hour-bar\" style=\"height:\(h)%\" title=\"\(count) 条\"></div>"
            html += "<span>\(hour)时</span></div>"
        }
        html += "</div></section>"

        // 月度趋势
        html += "<section><h2>月度消息量</h2>"
        if !monthOrder.isEmpty {
            let sortedMonths = monthOrder.sorted()
            let maxMonth = monthCounts.values.max() ?? 1
            for m in sortedMonths {
                let c = monthCounts[m] ?? 0
                let w = max(2, Int(Double(c) / Double(maxMonth) * 100))
                let isPeak = (peakMonth?.key == m)
                html += "<div class=\"bar-row\"><span class=\"bar-label\">\(escape(m))\(isPeak ? " 🏆" : "")</span>"
                html += "<div class=\"bar-track\"><div class=\"bar\" style=\"width:\(w)%\"></div></div>"
                html += "<span class=\"bar-value\">\(c)</span></div>"
            }
        } else {
            html += "<p class=\"sub\">无时间数据</p>"
        }
        html += "</section>"

        // 媒体构成
        html += "<section><h2>媒体构成</h2>"
        if !mediaKinds.isEmpty {
            for (kind, count) in mediaKinds.sorted(by: { $0.value > $1.value }) {
                let pct = totalMedia > 0 ? String(format: "%.1f%%", Double(count) / Double(totalMedia) * 100) : "0%"
                html += "<p>· \(escape(kind))：\(count)（\(pct)）</p>"
            }
        } else {
            html += "<p class=\"sub\">本次导出无媒体附件</p>"
        }
        html += "</section>"

        html += "<footer>由 WeChatExporter 本地生成 · 数据未离开你的设备" + Watermark.htmlFooter() + "</footer></body></html>"

        let safeName = sanitizeFilename(contactName.isEmpty ? "统计报告" : contactName)
        let outURL = destinationDir.appendingPathComponent("\(safeName)_统计_\(fileStamp()).html")
        do {
            try html.data(using: .utf8)?.write(to: outURL)
            log("统计报告已生成：\(outURL.lastPathComponent)")
            return outURL
        } catch {
            log("统计报告写入失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 工具函数（与 SingleFileExporter 保持一致的解析口径）

    private static func intField(_ row: [String: Any], keys: [String]) -> Int? {
        for k in keys {
            if let v = row[k] {
                if let n = v as? Int { return n }
                if let n = v as? Double { return Int(n) }
                if let s = v as? String, let n = Int(s) { return n }
            }
        }
        return nil
    }

    private static func stringField(_ row: [String: Any], keys: [String]) -> String? {
        for k in keys {
            if let v = row[k] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    private static func dateFromTimestamp(_ ts: Int) -> Date? {
        let seconds = ts > 100_000_000_000 ? ts / 1000 : ts
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return f
    }()

    private static func formatDate(_ d: Date) -> String { displayFormatter.string(from: d) }

    private static func dateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = .current
        return f.string(from: d)
    }

    private static func sanitizeFilename(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var out = s.replacingOccurrences(of: ".", with: " ")
        out = out.unicodeScalars.filter { !bad.contains($0) }.map { Character($0) }.reduce(into: "") { $0.append($1) }
        return out.isEmpty ? "聊天记录" : out
    }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = .current
        return f.string(from: Date())
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - 样式（与导出页同一暗色主题）

    private static let styles = """
    :root { --bg: #0b1026; --card: rgba(255,255,255,0.05); --cyan: #00f5ff; --purple: #7b61ff; --text: #f0f8ff; --sub: #9aa7c7; }
    * { box-sizing: border-box; }
    body { margin: 0; padding: 32px 16px; background: radial-gradient(1200px 600px at 50% -100px, #1b2a5e 0%, var(--bg) 60%); color: var(--text); font-family: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif; }
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
    .hour-cell:has(.hour-bar[style*="height:0%"]) .hour-bar { opacity: 0.25; }
    footer { text-align: center; color: var(--sub); font-size: 12px; margin-top: 24px; }
    """
}
