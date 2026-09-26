import Foundation

/// 年度报告（SPEC §5）：扫描导出根目录所有会话的 chat.json，
/// 生成单文件暗色科技风 HTML：概览卡 + 月度柱状 + 月×星期热力图 + 词频 Top30 + 跨会话排行 + 24 小时分布。
enum AnnualReportService {
    @discardableResult
    static func write(in base: URL, log: @escaping (String) -> Void) -> URL? {
        // 汇总所有 chat.json（递归；categorized 模式在 <会话>/文字/ 下）
        var rows: [[String: Any]] = []
        var sessionNames: [String] = []
        var jsonFiles: [URL] = []
        if let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in en where url.lastPathComponent == "chat.json" {
                jsonFiles.append(url)
            }
        }
        for jsonURL in jsonFiles {
            guard let data = try? Data(contentsOf: jsonURL),
                  let root = try? JSONSerialization.jsonObject(with: data) else { continue }
            let part: [[String: Any]]
            if let arr = root as? [[String: Any]] { part = arr }
            else if let dict = root as? [String: Any] {
                part = (dict["items"] as? [[String: Any]])
                    ?? (dict["messages"] as? [[String: Any]])
                    ?? (dict["results"] as? [[String: Any]])
                    ?? []
            } else { part = [] }
            if !part.isEmpty { sessionNames.append(jsonURL.deletingLastPathComponent().lastPathComponent) }
            rows.append(contentsOf: part)
        }
        guard !rows.isEmpty else {
            log("年度报告：无消息数据，跳过")
            return nil
        }

        // MARK: 聚合
        var timestamps: [Int] = []
        var senderCounts: [String: Int] = [:]
        var hourBuckets = [Int: Int](minimumCapacity: 24)
        var monthCounts: [String: Int] = [:]
        var weekdayMonth: [String: [Int: Int]] = [:]   // "2026-09" -> [weekday(0=周一): count]
        var daySet = Set<String>()                        // "yyyy-MM-dd"
        var wordFreq: [String: Int] = [:]
        var totalMedia = 0
        var mediaKinds: [String: Int] = [:]
        let tz = TimeZone(identifier: "Asia/Shanghai") ?? .current

        for row in rows {
            let nested = row["message"] as? [String: Any]
            let src = nested ?? row
            if let ts = intField(src, ["create_time", "timestamp"]) ?? intField(row, ["create_time", "timestamp"]), ts > 0 {
                timestamps.append(ts)
                let date = Date(timeIntervalSince1970: TimeInterval(ts))
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = tz
                let monthKeyFull = String(format: "%04d-%02d", cal.component(.year, from: date), cal.component(.month, from: date))
                monthCounts[monthKeyFull, default: 0] += 1
                daySet.insert(String(format: "%04d-%02d-%02d", cal.component(.year, from: date), cal.component(.month, from: date), cal.component(.day, from: date)))
                hourBuckets[cal.component(.hour, from: date), default: 0] += 1
                let weekday = cal.component(.weekday, from: date) - 1  // 0=周一
                weekdayMonth[monthKeyFull, default: [weekday: 0]][weekday, default: 0] += 1
            }
            let sender = stringField(row, ["sender_display_name", "sender", "from", "display_name"])
                ?? stringField(src, ["sender_display_name", "sender"]) ?? "未知"
            senderCounts[sender, default: 0] += 1
            let text = stringField(row, ["snippet", "content", "text", "message", "summary"])
                ?? stringField(src, ["content", "text"]) ?? ""
            for w in tokenize(text) { wordFreq[w, default: 0] += 1 }
            if let media = (row["media_files"] as? [String]) ?? (src["media_files"] as? [String]) {
                totalMedia += media.count
                for m in media {
                    let ext = (m as NSString).pathExtension.lowercased()
                    var kind = "其他"
                    switch ext {
                    case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp": kind = "图片"
                    case "silk", "pcm", "wav", "mp3", "m4a", "aac", "amr": kind = "语音"
                    case "mp4", "mov", "avi": kind = "视频"
                    default: break
                    }
                    mediaKinds[kind, default: 0] += 1
                }
            }
        }

        let peakMonth = monthCounts.max { $0.value < $1.value }?.key ?? ""
        let topSenders = senderCounts.sorted { $0.value > $1.value }.prefix(10)
        let topWords = wordFreq.sorted { $0.value > $1.value }.filter { $0.value > 1 }.prefix(30)
        let maxMonth = monthCounts.values.max() ?? 1
        let maxWeek = weekdayMonth.values.flatMap { $0.values }.max() ?? 1
        let maxSender = topSenders.first?.value ?? 1
        let maxWord = topWords.first?.value ?? 1
        let maxHour = hourBuckets.values.max() ?? 1
        let years = Set(timestamps.compactMap { ts -> Int? in
            guard ts > 0 else { return nil }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            return cal.component(.year, from: Date(timeIntervalSince1970: TimeInterval(ts)))
        })
        let year = years.max() ?? Calendar.current.component(.year, from: Date())

        // MARK: 数据内嵌 JSON（供页面交互；图表用 CSS 直渲染，双保险）
        let embeddedData: [String: Any] = [
            "year": year,
            "sessions": sessionNames.count,
            "messages": rows.count,
            "media": totalMedia,
            "activeDays": daySet.count,
            "peakMonth": peakMonth,
            "monthCounts": monthCounts,
            "weekdayMonth": weekdayMonth.mapValues { wdm in wdm.reduce(into: [String: Int]()) { $0[String($1.key)] = $1.value } },
            "hours": hourBuckets.reduce(into: [String: Int]()) { $0[String($1.key)] = $1.value },
            "topSenders": topSenders.map { ["name": $0.key, "count": $0.value] },
            "topWords": topWords.map { ["word": $0.key, "count": $0.value] },
        ]
        let json = String(data: (try? JSONSerialization.data(withJSONObject: embeddedData)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"

        // MARK: 渲染
        var html = ""
        html += "<!DOCTYPE html>\n<html lang=\"zh-CN\"><head><meta charset=\"utf-8\">"
        html += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        html += "<title>\(year) 微信聊天记录年度报告</title><style>" + styles + "</style></head><body>"
        html += Watermark.htmlOverlay()
        html += "<header><h1>📅 \(year) 年度报告</h1>"
        html += "<p class=\"sub\">\(sessionNames.count) 个会话 · \(rows.count) 条消息 · \(daySet.count) 个活跃天 · 峰值 \(peakMonth.isEmpty ? "—" : peakMonth + " 🏆")　·　生成于 \(dateNow())</p></header>"

        html += "<section class=\"cards\"><div class=\"card\"><div class=\"num\">\(sessionNames.count)</div><div>会话</div></div>"
        html += "<div class=\"card\"><div class=\"num\">\(rows.count)</div><div>消息总数</div></div>"
        html += "<div class=\"card\"><div class=\"num\">\(totalMedia)</div><div>媒体附件</div></div>"
        html += "<div class=\"card\"><div class=\"num\">\(daySet.count)</div><div>活跃天</div></div>"
        html += "<div class=\"card\"><div class=\"num\">\(peakMonth.isEmpty ? "—" : peakMonth)</div><div>峰值月份</div></div></section>"

        // 月度柱状
        html += "<section><h2>月度消息量</h2>"
        if monthCounts.isEmpty {
            html += "<p class=\"sub\">无时间数据</p>"
        } else {
            for m in monthCounts.keys.sorted() {
                let c = monthCounts[m] ?? 0
                let w = max(2, Int(Double(c) / Double(maxMonth) * 100))
                let peak = (m == peakMonth) ? " 🏆" : ""
                html += "<div class=\"bar-row\"><span class=\"bar-label\">\(m)\(peak)</span>"
                html += "<div class=\"bar-track\"><div class=\"bar\" style=\"width:\(w)%\"></div></div>"
                html += "<span class=\"bar-value\">\(c)</span></div>"
            }
        }
        html += "</section>"

        // 月×星期热力图
        let months = monthCounts.keys.sorted()
        html += "<section><h2>活跃热力图（月 × 星期）</h2>"
        if months.isEmpty {
            html += "<p class=\"sub\">无时间数据</p>"
        } else {
            html += "<div class=\"heat\"><div class=\"heat-header\"><div class=\"heat-month\"></div>"
            html += "<div class=\"heat-weekday\"><span>一</span><span>二</span><span>三</span><span>四</span><span>五</span><span>六</span><span>日</span></div></div>"
            for m in months {
                html += "<div class=\"heat-row\"><div class=\"heat-month\">\(m)</div>"
                for wd in 0..<7 {
                    let c = weekdayMonth[m]?[wd] ?? 0
                    let alpha = maxWeek > 0 ? min(1.0, 0.15 + Double(c) / Double(maxWeek) * 0.85) : 0.15
                    html += "<div class=\"heat-cell\" style=\"background:rgba(0,245,255,\(String(format: "%.2f", alpha)))\" title=\"\(m) 周\(wd) · \(c) 条\"></div>"
                }
                html += "</div>"
            }
            html += "</div>"
        }
        html += "</section>"

        // 词频
        html += "<section><h2>高频词 Top \(topWords.count)</h2>"
        if topWords.isEmpty {
            html += "<p class=\"sub\">暂无足够词频数据</p>"
        } else {
            var lines = ""
            for (word, count) in topWords {
                let w = max(3, Int(Double(count) / Double(maxWord) * 100))
                lines += "<div class=\"bar-row\"><span class=\"bar-label\">\(escape(word))</span>"
                lines += "<div class=\"bar-track\"><div class=\"bar\" style=\"width:\(w)%\"></div></div>"
                lines += "<span class=\"bar-value\">\(count)</span></div>"
            }
            html += lines
        }
        html += "</section>"

        // 排行
        html += "<section><h2>跨会话发言排行</h2>"
        if topSenders.isEmpty {
            html += "<p class=\"sub\">无发言数据</p>"
        } else {
            var lines = ""
            for (name, count) in topSenders {
                let w = max(3, Int(Double(count) / Double(maxSender) * 100))
                lines += "<div class=\"bar-row\"><span class=\"bar-label\">\(escape(name))</span>"
                lines += "<div class=\"bar-track\"><div class=\"bar\" style=\"width:\(w)%\"></div></div>"
                lines += "<span class=\"bar-value\">\(count)</span></div>"
            }
            html += lines
        }
        html += "</section>"

        // 24 小时
        html += "<section><h2>24 小时活跃分布</h2><div class=\"hours\">"
        for h in 0..<24 {
            let c = hourBuckets[h] ?? 0
            let hh = maxHour > 0 ? Int(round(Double(c) / Double(maxHour) * 100)) : 0
            html += "<div class=\"hour-cell\"><div class=\"hour-bar\" style=\"height:\(hh)%\" title=\"\(c) 条\"></div><span>\(h)时</span></div>"
        }
        html += "</div></section>"

        html += "<footer>由 WeChatExporter 本地生成 · 数据未离开你的设备" + Watermark.htmlFooter() + "</footer>"
        html += "<script>const DATA=" + json + ";</script>"
        html += "</body></html>"

        let outURL = base.appendingPathComponent("年度报告_\(year).html")
        do {
            try html.data(using: .utf8)?.write(to: outURL)
            log("年度报告已生成：\(outURL.lastPathComponent)")
            return outURL
        } catch {
            log("年度报告写入失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 分词（CJK bigram + 拉丁单词）

    private static let stopwords: Set<String> = [
        "的", "了", "我", "你", "他", "她", "它", "我们", "你们", "是", "在", "有", "和", "就",
        "都", "也", "还", "会", "这", "那", "个", "啊", "呀", "哦", "嗯", "呢", "吗", "吧",
        "被", "把", "让", "对", "跟", "不", "没", "么", "什么", "这个", "那个", "一个",
        "the", "a", "an", "is", "are", "to", "of", "and", "in", "on", "at", "it", "this", "that",
        "ok", "haha", "哈哈", "好的", "嗯嗯", "收到", "可以", "不用", "谢谢",
    ]

    private static func tokenize(_ text: String) -> [String] {
        var words: [String] = []
        var cjk = ""
        var latin = ""

        func flushLatin() {
            let w = latin.lowercased()
            latin = ""
            if w.count >= 2, !stopwords.contains(w) { words.append(w) }
        }
        func flushCJK() {
            let chars = Array(cjk)
            cjk = ""
            if chars.count == 1 {
                let s = String(chars)
                if !stopwords.contains(s) { words.append(s) }
                return
            }
            guard chars.count >= 2 else { return }
            for i in 0..<(chars.count - 1) {
                let pair = String(chars[i...i + 1])
                if !stopwords.contains(pair) { words.append(pair) }
            }
        }

        for ch in text {
            let v = ch.unicodeScalars.first?.value ?? 0
            if (0x4E00...0x9FFF).contains(v) {
                flushLatin()
                cjk.append(ch)
            } else if ch.isLetter || ch.isNumber {
                flushCJK()
                latin.append(ch)
            } else {
                flushLatin()
                flushCJK()
            }
        }
        flushLatin()
        flushCJK()
        return words
    }

    // MARK: - 工具

    private static func intField(_ row: [String: Any], _ keys: [String]) -> Int? {
        for k in keys {
            if let v = row[k] {
                if let n = v as? Int { return n }
                if let n = v as? Double { return Int(n) }
                if let s = v as? String, let n = Int(s) { return n }
            }
        }
        return nil
    }

    private static func stringField(_ row: [String: Any], _ keys: [String]) -> String? {
        for k in keys {
            if let v = row[k] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    private static func dateNow() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let styles = """
    :root { --bg: #0b1026; --card: rgba(255,255,255,0.05); --cyan: #00f5ff; --purple: #7b61ff; --text: #f0f8ff; --sub: #9aa7c7; }
    * { box-sizing: border-box; }
    body { margin: 0; padding: 32px 16px; background: radial-gradient(1200px 600px at 50% -100px, #1b2a5e 0%, var(--bg) 60%); color: var(--text); font-family: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif; }
    header, section { max-width: 920px; margin: 0 auto 20px; }
    header { text-align: center; }
    h1 { font-size: 26px; margin: 0 0 8px; }
    .sub { color: var(--sub); font-size: 13px; }
    .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; }
    .card { background: var(--card); border: 1px solid rgba(0,245,255,0.18); border-radius: 14px; padding: 16px; text-align: center; }
    .card .num { font-size: 26px; font-weight: 700; color: var(--cyan); word-break: break-all; }
    section { background: var(--card); border: 1px solid rgba(0,245,255,0.14); border-radius: 14px; padding: 20px; }
    h2 { font-size: 17px; margin: 0 0 14px; color: var(--cyan); }
    .bar-row { display: flex; align-items: center; gap: 10px; margin: 7px 0; font-size: 13px; }
    .bar-label { width: 120px; text-align: right; color: var(--text); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bar-track { flex: 1; height: 13px; background: rgba(255,255,255,0.07); border-radius: 7px; overflow: hidden; }
    .bar { height: 100%; background: linear-gradient(90deg, var(--cyan), var(--purple)); border-radius: 7px; }
    .bar-value { width: 70px; color: var(--sub); }
    .heat { display: inline-grid; grid-auto-flow: column; gap: 3px; align-items: center; }
    .heat-weekday { display: flex; flex-direction: column; gap: 3px; margin-left: 84px; }
    .heat-weekday span { height: 14px; line-height: 14px; font-size: 10px; color: var(--sub); text-align: center; }
    .heat-row { display: flex; gap: 3px; align-items: center; margin: 3px 0; }
    .heat-month { width: 76px; font-size: 11px; color: var(--sub); }
    .heat-cell { width: 16px; height: 14px; border-radius: 3px; }
    .hours { display: grid; grid-template-columns: repeat(12, 1fr); gap: 6px; }
    .hour-cell { text-align: center; font-size: 11px; color: var(--sub); }
    .hour-bar { margin: 0 auto 4px; width: 70%; min-height: 3px; height: 56px; display: flex; align-items: flex-end; background: linear-gradient(180deg, var(--cyan), var(--purple)); border-radius: 4px 4px 0 0; }
    footer { text-align: center; color: var(--sub); font-size: 12px; margin-top: 24px; max-width: 920px; margin-left: auto; margin-right: auto; }
    """
}
