import Foundation

/// 日历提取（SPEC §6）：从聊天消息里启发式识别时间承诺/约定，
/// 生成 日历事件.json + 日历事件.ics（TZID=Asia/Shanghai，VEVENT 默认 60 分钟）。
enum CalendarExtractService {
    static let jsonName = "日历事件.json"
    static let icsName = "日历事件.ics"

    struct Event: Codable {
        let session: String
        let messageTs: Int
        let summary: String
        let start: String  // "YYYY-MM-DD HH:mm" Asia/Shanghai
        let end: String
        let raw: String
    }

    struct ParsedDay {
        var year: Int
        var month: Int
        var day: Int
        var hour: Int
        var minute: Int
        /// true = 相对偏移解析（offsetDay 已加到基准日）；false = 绝对日期
        var isRelative: Bool
        var offsetDay: Int
    }

    @discardableResult
    static func extract(in base: URL, log: @escaping (String) -> Void) -> Int {
        let tz = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var events: [Event] = []

        var jsonFiles: [URL] = []
        if let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in en where url.lastPathComponent == "chat.json" {
                jsonFiles.append(url)
            }
        }
        for jsonURL in jsonFiles {
            guard let data = try? Data(contentsOf: jsonURL),
                  let root = try? JSONSerialization.jsonObject(with: data) else { continue }
            let sessionName = jsonURL.deletingLastPathComponent().lastPathComponent
            let rows: [[String: Any]]
            if let arr = root as? [[String: Any]] { rows = arr }
            else if let dict = root as? [String: Any] {
                rows = (dict["items"] as? [[String: Any]])
                    ?? (dict["messages"] as? [[String: Any]])
                    ?? (dict["results"] as? [[String: Any]])
                    ?? []
            } else { rows = [] }

            for row in rows {
                let nested = row["message"] as? [String: Any]
                let src = nested ?? row
                guard let ts = intField(src, ["create_time", "timestamp"]) ?? intField(row, ["create_time", "timestamp"]), ts > 0 else { continue }
                let text = stringField(row, ["snippet", "content", "text"])
                    ?? stringField(src, ["content", "text"]) ?? ""
                guard let day = parseDay(from: text, msgTs: ts) else { continue }
                let msgDate = Date(timeIntervalSince1970: TimeInterval(ts))

                var date: Date
                if day.isRelative {
                    let baseDate = cal.date(byAdding: .day, value: day.offsetDay, to: msgDate) ?? msgDate
                    date = setHourMinute(baseDate, hour: day.hour, minute: day.minute, cal: cal)
                } else {
                    var c = DateComponents()
                    c.year = day.year
                    c.month = day.month
                    c.day = day.day
                    c.hour = day.hour
                    c.minute = day.minute
                    var candidate = cal.date(from: c) ?? msgDate
                    // 绝对日期早于消息时刻 → 次年（SPEC：M月D日默认当年，早了 +1）
                    if candidate < msgDate {
                        c.year = day.year + 1
                        candidate = cal.date(from: c) ?? candidate
                    }
                    date = candidate
                }

                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH:mm"
                f.timeZone = tz
                let start = f.string(from: date)
                let end = f.string(from: date.addingTimeInterval(3600))
                let summary = String(text.prefix(60)).replacingOccurrences(of: "\n", with: " ")
                events.append(Event(
                    session: sessionName,
                    messageTs: ts,
                    summary: summary,
                    start: start,
                    end: end,
                    raw: String(text.prefix(120))
                ))
            }
        }

        let jsonURL = base.appendingPathComponent(jsonName)
        if let data = try? JSONEncoder().encode(events) {
            _ = try? data.write(to: jsonURL)
        }
        _ = try? writeIcs(events, to: base.appendingPathComponent(icsName))
        log("日历事件已生成：\(icsName) + \(jsonName)（\(events.count) 条）")
        return events.count
    }

    // MARK: - 解析（SPEC §6 规则；全部本地计算，无全局状态）

    private static func parseDay(from text: String, msgTs: Int) -> ParsedDay? {
        let tz = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let msgDate = Date(timeIntervalSince1970: TimeInterval(msgTs))
        let msgComps = cal.dateComponents([.year, .month, .day, .weekday], from: msgDate)
        let msgYear = msgComps.year ?? 2026
        let msgWeekday = msgComps.weekday ?? 1  // 1=周日 … 7=周六

        var hour = 9
        var minute = 0
        var timeHit = false

        // 1) 相对天词（按优先级命中即停）
        var offset: Int?
        for (word, off) in [("大后天", 3), ("后天", 2), ("明天", 1), ("今晚", 0), ("今天", 0)] where text.contains(word) {
            offset = off
            if word == "今晚" { hour = 20; timeHit = true }
            break
        }

        // 2) 周X / 星期X：最近的未来那一天
        if offset == nil {
            let map: [(String, Int)] = [
                ("周一", 2), ("周二", 3), ("周三", 4), ("周四", 5),
                ("周五", 6), ("周六", 7), ("周日", 1), ("周天", 1),
            ]
            for (word, target) in map {
                if text.contains(word) || text.contains("星期" + word.suffix(1)) {
                    var delta = target - msgWeekday
                    if delta <= 0 { delta += 7 }
                    offset = delta
                    break
                }
            }
        }

        // 3) 绝对日期 M月D日
        var absY: Int?
        var absM: Int?
        var absD: Int?
        if let re = try? NSRegularExpression(pattern: "(\\d{1,2})月(\\d{1,2})日") {
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges == 3 {
                let mo = Int(ns.substring(with: m.range(at: 1))) ?? 0
                let dy = Int(ns.substring(with: m.range(at: 2))) ?? 0
                if (1...12).contains(mo), (1...31).contains(dy) {
                    absM = mo
                    absD = dy
                }
            }
        }
        // 4) 绝对日期 YYYY-MM-DD / YYYY/MM/DD
        if absM == nil, let re = try? NSRegularExpression(pattern: "(\\d{4})[-/](\\d{1,2})[-/](\\d{1,2})") {
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges == 4 {
                let y = Int(ns.substring(with: m.range(at: 1))) ?? 0
                let mo = Int(ns.substring(with: m.range(at: 2))) ?? 0
                let dy = Int(ns.substring(with: m.range(at: 3))) ?? 0
                if y > 2000, (1...12).contains(mo), (1...31).contains(dy) {
                    absY = y
                    absM = mo
                    absD = dy
                    break
                }
            }
        }

        // 5) 时刻词：上午/早上/中午/下午/晚上 + N点(半)
        for (word, isPM) in [("上午", false), ("早上", false), ("中午", false), ("下午", true), ("晚上", true)] {
            guard let idx = text.range(of: word)?.upperBound else { continue }
            let tail = String(text[idx...])
            if let (h, m) = firstHour(in: tail, pm: isPM) {
                hour = h
                minute = m
                timeHit = true
            }
            break
        }
        // 6) 裸 N点 / N点半
        if !timeHit {
            if let (h, m) = firstHour(in: text, pm: false) {
                hour = h
                minute = m
                timeHit = true
            }
        }

        // 必须至少命中一个天词/日期/时刻词
        guard offset != nil || absM != nil || timeHit else { return nil }

        if absM != nil {
            return ParsedDay(
                year: absY ?? msgYear, month: absM!, day: absD ?? 1,
                hour: hour, minute: minute, isRelative: false, offsetDay: 0
            )
        }
        return ParsedDay(
            year: 0, month: 0, day: 0,
            hour: hour, minute: minute, isRelative: true, offsetDay: offset ?? 0
        )
    }

    /// 取文本中第一个 N点(半)；pm=true 时 N<12 加 12。
    private static func firstHour(in s: String, pm: Bool) -> (Int, Int)? {
        guard let re = try? NSRegularExpression(pattern: "(\\d{1,2})点半?") else { return nil }
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges == 2 {
            let raw = Int(ns.substring(with: m.range(at: 1))) ?? -1
            guard raw >= 0, raw <= 23 else { continue }
            var h = raw
            if pm && h < 12 { h += 12 }
            guard (0...23).contains(h) else { continue }
            let minute = ns.substring(with: m.range(at: 0)).contains("半") ? 30 : 0
            return (h, minute)
        }
        return nil
    }

    private static func setHourMinute(_ d: Date, hour: Int, minute: Int, cal: Calendar) -> Date {
        var c = cal.dateComponents([.year, .month, .day], from: d)
        c.hour = hour
        c.minute = minute
        c.second = 0
        return cal.date(from: c) ?? d
    }

    // MARK: - ICS

    private static func writeIcs(_ events: [Event], to url: URL) throws -> Data {
        let tz = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let stampF = DateFormatter()
        stampF.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        stampF.timeZone = TimeZone(identifier: "UTC")
        let conv = { (d: Date) -> String in
            let cf = DateFormatter()
            cf.dateFormat = "yyyyMMdd'T'HHmmss"
            cf.timeZone = tz
            return cf.string(from: d)
        }
        let lineF = DateFormatter()
        lineF.dateFormat = "yyyy-MM-dd HH:mm"
        lineF.timeZone = tz

        var out = "BEGIN:VCALENDAR\r\n"
        out += "VERSION:2.0\r\n"
        out += "PRODID:-//WeChatExporter//CN\r\n"
        out += "CALSCALE:GREGORIAN\r\n"
        out += "X-WR-CALNAME:微信聊天记录导出·日历事件\r\n"
        out += "X-WR-TIMEZONE:Asia/Shanghai\r\n"
        out += "BEGIN:VTIMEZONE\r\nTZID:Asia/Shanghai\r\n"
        out += "BEGIN:STANDARD\r\nDTSTART:19700101T000000\r\nTZOFFSETFROM:+0800\r\nTZOFFSETTO:+0800\r\nTZNAME:CST\r\nEND:STANDARD\r\n"
        out += "END:VTIMEZONE\r\n"
        for e in events {
            guard let s = lineF.date(from: e.start), let en = lineF.date(from: e.end) else { continue }
            let uid = sha1("\(e.session)|\(e.messageTs)|\(e.start)")
            out += "BEGIN:VEVENT\r\n"
            out += "UID:\(uid)@wce\r\n"
            out += "DTSTAMP:\(stampF.string(from: Date()))\r\n"
            out += "DTSTART;TZID=Asia/Shanghai:\(conv(s))\r\n"
            out += "DTEND;TZID=Asia/Shanghai:\(conv(en))\r\n"
            out += "SUMMARY:\(e.session)｜\(e.summary)\r\n"
            out += "DESCRIPTION:原文：\(e.raw)\r\n"
            out += "END:VEVENT\r\n"
        }
        out += "END:VCALENDAR\r\n"
        let data = Data(out.utf8)
        try data.write(to: url)
        return data
    }

    private static func sha1(_ s: String) -> String {
        // 确定性 FNV-1a 64 位（ICS 的 UID 只需稳定，无需加密强度）
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    // MARK: - 小工具（与 ChatStatsReport 解析口径一致）

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
}
