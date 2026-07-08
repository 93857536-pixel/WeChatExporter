import Foundation

/// 将导出目录中的聊天记录与媒体打包为单个自包含 HTML 文件（图片/表情/音视频以 base64 内嵌）。
enum SingleFileExporter {
    struct MessageRow {
        let time: String
        let sender: String
        let type: String
        let content: String
        let mediaPaths: [String]
    }

    /// 从已导出的临时目录生成 HTML，写入 `destinationDir`，返回 HTML 文件 URL。
    static func writeHTML(from sourceDir: URL, contactName: String, into destinationDir: URL) throws -> URL {
        let jsonURL = sourceDir.appendingPathComponent("chat.json")
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw AppError.exportFailed("未找到 chat.json，无法生成单文件导出")
        }

        let rows = try parseMessages(from: jsonURL)
        guard !rows.isEmpty else {
            throw AppError.exportFailed("聊天记录为空，无法生成单文件导出")
        }

        let safeName = sanitizeFilename(contactName.isEmpty ? "聊天记录" : contactName)
        let stamp = Self.fileStamp()
        let outURL = destinationDir.appendingPathComponent("\(safeName)_\(stamp).html")

        let title = escapeHTML(contactName.isEmpty ? "微信聊天记录" : contactName)
        var body = ""
        var embedded = Set<String>()
        for row in rows {
            body += renderMessage(row, sourceDir: sourceDir, embedded: &embedded)
        }
        body += renderOrphanMedia(sourceDir: sourceDir, embedded: &embedded)

        let html = """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8"/>
          <meta name="viewport" content="width=device-width, initial-scale=1"/>
          <title>\(title)</title>
          <style>
            \(exportStyles)
          </style>
        </head>
        <body>
          <div class="bg-scene" aria-hidden="true">
            <div class="aurora aurora-a"></div>
            <div class="aurora aurora-b"></div>
            <div class="aurora aurora-c"></div>
            <div class="grid-floor"></div>
          </div>
          <header>
            <div class="header-glow"></div>
            <p class="eyebrow">WeChatExporter · 单文件导出</p>
            <h1>\(title)</h1>
            <div class="stats">
              <span class="pill pill-cyan">\(rows.count) 条消息</span>
              <span class="pill pill-purple">媒体已内嵌</span>
              <span class="pill pill-muted">\(stamp)</span>
            </div>
          </header>
          <main>
        \(body)
          </main>
          <footer>
            <span class="footer-brand">WeChatExporter</span>
            <span class="footer-dot">·</span>
            <span>深空霓虹主题 · 浏览器离线可阅</span>
          </footer>
        </body>
        </html>
        """

        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        try html.write(to: outURL, atomically: true, encoding: .utf8)
        return outURL
    }

    /// 从 `stickers-manifest.json` 生成全部表情包画廊 HTML。
    static func writeStickerGallery(from sourceDir: URL, into destinationDir: URL) throws -> URL? {
        let manifestURL = sourceDir.appendingPathComponent("stickers-manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(StickerPackExporter.Manifest.self, from: data),
              !manifest.packs.isEmpty else {
            return nil
        }

        let stamp = fileStamp()
        let outURL = destinationDir.appendingPathComponent("全部表情包_\(stamp).html")
        var body = ""
        for pack in manifest.packs {
            body += renderStickerPack(pack, sourceDir: sourceDir)
        }

        let html = """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8"/>
          <meta name="viewport" content="width=device-width, initial-scale=1"/>
          <title>全部表情包</title>
          <style>
            \(exportStyles)
            \(galleryStyles)
          </style>
        </head>
        <body>
          <div class="bg-scene" aria-hidden="true">
            <div class="aurora aurora-a"></div>
            <div class="aurora aurora-b"></div>
            <div class="aurora aurora-c"></div>
            <div class="grid-floor"></div>
          </div>
          <header>
            <div class="header-glow"></div>
            <p class="eyebrow">WeChatExporter · 表情包库</p>
            <h1>全部表情包</h1>
            <div class="stats">
              <span class="pill pill-cyan">\(manifest.totalCount) 张表情</span>
              <span class="pill pill-purple">\(manifest.packs.count) 个分组</span>
              <span class="pill pill-muted">\(stamp)</span>
            </div>
          </header>
          <main>
        \(body)
          </main>
          <footer>
            <span class="footer-brand">WeChatExporter</span>
            <span class="footer-dot">·</span>
            <span>收藏与商店表情包 · 浏览器离线可阅</span>
          </footer>
        </body>
        </html>
        """

        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        try html.write(to: outURL, atomically: true, encoding: .utf8)
        return outURL
    }

    private static func renderStickerPack(_ pack: StickerPackExporter.StickerPack, sourceDir: URL) -> String {
        var tiles = ""
        for sticker in pack.stickers {
            guard let block = embedMedia(relativePath: sticker.path, sourceDir: sourceDir) else { continue }
            let caption = escapeHTML(sticker.caption)
            tiles += """
                <figure class="sticker-tile">
                  \(block)
                  \(caption.isEmpty ? "" : "<figcaption>\(caption)</figcaption>")
                </figure>

            """
        }
        guard !tiles.isEmpty else { return "" }
        return """
            <section class="sticker-pack">
              <h2>\(escapeHTML(pack.name)) <span class="pack-count">\(pack.stickers.count)</span></h2>
              <div class="sticker-grid">\(tiles)</div>
            </section>

        """
    }

    private static let galleryStyles = """
    .sticker-pack { margin-bottom: 36px; }
    .sticker-pack h2 {
      margin: 0 0 14px;
      font-size: 18px;
      color: var(--cyan);
      text-shadow: 0 0 12px rgba(0,245,255,0.35);
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .pack-count {
      font-size: 12px;
      color: var(--subtext);
      padding: 2px 8px;
      border-radius: 999px;
      border: 1px solid rgba(123,97,255,0.35);
      background: rgba(123,97,255,0.12);
    }
    .sticker-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(92px, 1fr));
      gap: 12px;
    }
    .sticker-tile {
      margin: 0;
      background: rgba(12,20,48,0.55);
      border: 1px solid rgba(0,245,255,0.18);
      border-radius: 12px;
      padding: 8px;
      box-shadow: 0 0 16px rgba(123,97,255,0.08);
      transition: border-color 0.2s ease, transform 0.2s ease;
    }
    .sticker-tile:hover {
      border-color: rgba(0,245,255,0.42);
      transform: translateY(-2px);
    }
    .sticker-tile img {
      width: 100%;
      height: auto;
      display: block;
      border-radius: 8px;
      border: none;
      box-shadow: none;
    }
    .sticker-tile figcaption {
      margin-top: 6px;
      font-size: 11px;
      color: var(--subtext);
      text-align: center;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    """

    /// 与 DMG 安装界面一致的深空霓虹 HUD 样式（青 #00f5ff · 紫 #7b61ff · 品红 #ff4dd2）
    private static let exportStyles = """
    :root {
      --cyan: #00f5ff;
      --purple: #7b61ff;
      --magenta: #ff4dd2;
      --green: #07ffa0;
      --text: #f0f8ff;
      --subtext: #8caad2;
      --glass: rgba(12, 20, 48, 0.78);
      --glass-strong: rgba(8, 14, 36, 0.92);
      --line: rgba(0, 245, 255, 0.22);
    }
    * { box-sizing: border-box; }
    html { scroll-behavior: smooth; }
    body {
      margin: 0;
      min-height: 100vh;
      font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Segoe UI", sans-serif;
      color: var(--text);
      background: linear-gradient(145deg, #080a20 0%, #120830 38%, #06122a 72%, #1c0626 100%);
      background-attachment: fixed;
      position: relative;
      overflow-x: hidden;
    }
    body::before {
      content: "";
      position: fixed;
      inset: 0;
      pointer-events: none;
      z-index: 0;
      opacity: 0.55;
      background-image:
        radial-gradient(1px 1px at 8% 14%, rgba(240,248,255,0.95) 50%, transparent 51%),
        radial-gradient(1px 1px at 22% 38%, rgba(0,245,255,0.85) 50%, transparent 51%),
        radial-gradient(1.5px 1.5px at 35% 8%, rgba(123,97,255,0.9) 50%, transparent 51%),
        radial-gradient(1px 1px at 48% 62%, rgba(240,248,255,0.75) 50%, transparent 51%),
        radial-gradient(1px 1px at 61% 24%, rgba(0,245,255,0.7) 50%, transparent 51%),
        radial-gradient(1.5px 1.5px at 74% 72%, rgba(255,77,210,0.8) 50%, transparent 51%),
        radial-gradient(1px 1px at 86% 18%, rgba(240,248,255,0.8) 50%, transparent 51%),
        radial-gradient(1px 1px at 92% 48%, rgba(123,97,255,0.75) 50%, transparent 51%),
        radial-gradient(2px 2px at 16% 82%, rgba(0,245,255,0.65) 50%, transparent 51%),
        radial-gradient(1px 1px at 54% 88%, rgba(240,248,255,0.7) 50%, transparent 51%);
    }
    .bg-scene { position: fixed; inset: 0; pointer-events: none; z-index: 0; overflow: hidden; }
    .aurora {
      position: absolute;
      border-radius: 50%;
      filter: blur(72px);
      opacity: 0.42;
      animation: drift 18s ease-in-out infinite alternate;
    }
    .aurora-a {
      width: 420px; height: 180px;
      top: -40px; left: 12%;
      background: radial-gradient(circle, rgba(0,180,255,0.55), transparent 70%);
    }
    .aurora-b {
      width: 380px; height: 160px;
      top: 60px; right: 8%;
      background: radial-gradient(circle, rgba(140,60,255,0.5), transparent 70%);
      animation-delay: -6s;
    }
    .aurora-c {
      width: 500px; height: 200px;
      bottom: 18%; left: 28%;
      background: radial-gradient(circle, rgba(255,60,200,0.35), transparent 70%);
      animation-delay: -12s;
    }
    .grid-floor {
      position: absolute;
      left: 0; right: 0; bottom: 0;
      height: 42vh;
      background:
        linear-gradient(to bottom, transparent 0%, rgba(0,245,255,0.04) 100%),
        repeating-linear-gradient(90deg, transparent, transparent 39px, rgba(0,245,255,0.06) 39px, rgba(0,245,255,0.06) 40px),
        repeating-linear-gradient(0deg, transparent, transparent 13px, rgba(123,97,255,0.05) 13px, rgba(123,97,255,0.05) 14px);
      transform: perspective(480px) rotateX(62deg);
      transform-origin: center bottom;
      mask-image: linear-gradient(to top, rgba(0,0,0,0.55), transparent);
      opacity: 0.35;
    }
    @keyframes drift {
      from { transform: translate3d(-12px, 0, 0) scale(1); }
      to { transform: translate3d(18px, 14px, 0) scale(1.06); }
    }
    header, main, footer { position: relative; z-index: 1; }
    header {
      padding: 32px 24px 28px;
      background: linear-gradient(180deg, rgba(12,20,48,0.88), rgba(8,14,36,0.72));
      backdrop-filter: blur(18px) saturate(140%);
      -webkit-backdrop-filter: blur(18px) saturate(140%);
      border-bottom: 1px solid var(--line);
      box-shadow: 0 12px 40px rgba(0,0,0,0.35), inset 0 1px 0 rgba(255,255,255,0.06);
    }
    .header-glow {
      position: absolute;
      top: 0; left: 50%;
      width: min(680px, 90vw);
      height: 2px;
      transform: translateX(-50%);
      background: linear-gradient(90deg, transparent, var(--cyan), var(--purple), var(--magenta), transparent);
      box-shadow: 0 0 24px rgba(0,245,255,0.55);
    }
    .eyebrow {
      margin: 0 0 10px;
      font-size: 11px;
      letter-spacing: 0.22em;
      text-transform: uppercase;
      color: var(--subtext);
    }
    header h1 {
      margin: 0 0 16px;
      font-size: clamp(24px, 4vw, 34px);
      font-weight: 700;
      line-height: 1.2;
      background: linear-gradient(92deg, var(--cyan) 0%, #9ae8ff 35%, var(--purple) 68%, var(--magenta) 100%);
      -webkit-background-clip: text;
      background-clip: text;
      color: transparent;
      filter: drop-shadow(0 0 18px rgba(0,245,255,0.35));
    }
    .stats { display: flex; flex-wrap: wrap; gap: 8px; }
    .pill {
      display: inline-flex;
      align-items: center;
      padding: 5px 12px;
      border-radius: 999px;
      font-size: 12px;
      letter-spacing: 0.02em;
      border: 1px solid transparent;
    }
    .pill-cyan {
      color: var(--cyan);
      background: rgba(0,245,255,0.1);
      border-color: rgba(0,245,255,0.35);
      box-shadow: 0 0 16px rgba(0,245,255,0.18);
    }
    .pill-purple {
      color: #c4b5ff;
      background: rgba(123,97,255,0.14);
      border-color: rgba(123,97,255,0.38);
      box-shadow: 0 0 16px rgba(123,97,255,0.18);
    }
    .pill-muted {
      color: var(--subtext);
      background: rgba(140,170,210,0.08);
      border-color: rgba(140,170,210,0.22);
    }
    main {
      max-width: 880px;
      margin: 0 auto;
      padding: 28px 16px 56px;
    }
    .msg {
      position: relative;
      background: var(--glass);
      backdrop-filter: blur(14px) saturate(130%);
      -webkit-backdrop-filter: blur(14px) saturate(130%);
      border: 1px solid rgba(123,97,255,0.28);
      border-radius: 16px;
      padding: 16px 18px 18px;
      margin-bottom: 14px;
      box-shadow:
        0 8px 32px rgba(0,0,0,0.32),
        inset 0 1px 0 rgba(255,255,255,0.05),
        0 0 24px rgba(123,97,255,0.08);
      transition: border-color 0.25s ease, box-shadow 0.25s ease, transform 0.25s ease;
    }
    .msg::before {
      content: "";
      position: absolute;
      top: 12px; left: 12px;
      width: 18px; height: 18px;
      border-top: 2px solid rgba(0,245,255,0.55);
      border-left: 2px solid rgba(0,245,255,0.55);
      border-radius: 4px 0 0 0;
      pointer-events: none;
    }
    .msg::after {
      content: "";
      position: absolute;
      bottom: 12px; right: 12px;
      width: 18px; height: 18px;
      border-bottom: 2px solid rgba(123,97,255,0.45);
      border-right: 2px solid rgba(123,97,255,0.45);
      border-radius: 0 0 4px 0;
      pointer-events: none;
    }
    .msg:hover {
      border-color: rgba(0,245,255,0.42);
      box-shadow:
        0 10px 36px rgba(0,0,0,0.38),
        0 0 28px rgba(0,245,255,0.12),
        inset 0 1px 0 rgba(255,255,255,0.07);
      transform: translateY(-1px);
    }
    .meta {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 8px;
      margin-bottom: 10px;
      font-size: 12px;
    }
    .sender {
      font-weight: 600;
      color: var(--cyan);
      text-shadow: 0 0 10px rgba(0,245,255,0.45);
    }
    .type {
      display: inline-flex;
      align-items: center;
      padding: 2px 9px;
      border-radius: 999px;
      font-size: 11px;
      color: #d5c8ff;
      background: rgba(123,97,255,0.18);
      border: 1px solid rgba(123,97,255,0.42);
      box-shadow: 0 0 12px rgba(123,97,255,0.2);
    }
    .time {
      color: var(--subtext);
      margin-left: auto;
      font-variant-numeric: tabular-nums;
    }
    .text {
      white-space: pre-wrap;
      word-break: break-word;
      line-height: 1.65;
      color: rgba(240,248,255,0.94);
    }
    .media { margin-top: 12px; }
    .media img, .media .chat-img {
      max-width: min(100%, 440px);
      border-radius: 12px;
      display: block;
      border: 1px solid rgba(0,245,255,0.32);
      box-shadow: 0 0 24px rgba(0,245,255,0.18), 0 8px 24px rgba(0,0,0,0.35);
      cursor: zoom-in;
    }
    .media img:active, .media .chat-img:active { transform: scale(1.01); }
    .media video, .media audio {
      max-width: 100%;
      margin-top: 8px;
      display: block;
      border-radius: 12px;
      border: 1px solid rgba(123,97,255,0.28);
      box-shadow: 0 0 20px rgba(123,97,255,0.15);
      background: var(--glass-strong);
    }
    footer {
      text-align: center;
      color: var(--subtext);
      font-size: 12px;
      padding: 28px 16px 36px;
      border-top: 1px solid rgba(123,97,255,0.15);
      background: linear-gradient(180deg, transparent, rgba(8,14,36,0.55));
    }
    .footer-brand {
      color: var(--cyan);
      font-weight: 600;
      text-shadow: 0 0 10px rgba(0,245,255,0.35);
    }
    .footer-dot { margin: 0 8px; opacity: 0.5; }
    @media (max-width: 640px) {
      header { padding: 24px 16px 22px; }
      .time { margin-left: 0; width: 100%; }
      .msg { padding: 14px 14px 16px; }
    }
    """

    private static func renderMessage(_ row: MessageRow, sourceDir: URL, embedded: inout Set<String>) -> String {
        var mediaHTML = ""
        for rel in row.mediaPaths {
            guard embedded.insert(rel).inserted else { continue }
            if let block = embedMedia(relativePath: rel, sourceDir: sourceDir) {
                mediaHTML += block
            }
        }

        let content = escapeHTML(row.content)
        let showText = !content.isEmpty && content != "[图片]" && content != "[语音]" && content != "[视频]" && content != "[表情]"

        return """
            <article class="msg">
              <div class="meta">
                <span class="sender">\(escapeHTML(row.sender))</span>
                <span class="type">\(escapeHTML(row.type))</span>
                <span class="time">\(escapeHTML(row.time))</span>
              </div>
              \(showText ? "<div class=\"text\">\(content)</div>" : "")
              \(mediaHTML.isEmpty ? "" : "<div class=\"media\">\(mediaHTML)</div>")
            </article>

        """
    }

    private static func renderOrphanMedia(sourceDir: URL, embedded: inout Set<String>) -> String {
        let mediaRoot = sourceDir.appendingPathComponent("media", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: mediaRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return "" }

        var html = ""
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = "media/" + fileURL.path.replacingOccurrences(of: mediaRoot.path + "/", with: "")
            guard embedded.insert(rel).inserted else { continue }
            guard let block = embedMedia(relativePath: rel, sourceDir: sourceDir) else { continue }
            html += """
                <article class="msg">
                  <div class="meta">
                    <span class="sender">媒体附件</span>
                    <span class="type">文件</span>
                    <span class="time">\(escapeHTML(fileURL.lastPathComponent))</span>
                  </div>
                  <div class="media">\(block)</div>
                </article>

            """
        }
        return html
    }

    private static func embedMedia(relativePath: String, sourceDir: URL) -> String? {
        let rel = relativePath.hasPrefix("media/") ? relativePath : "media/\(relativePath)"
        let fileURL = sourceDir.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let ext = fileURL.pathExtension.lowercased()
        if ext == "dat" || ext == "wxgf" {
            let base = fileURL.deletingPathExtension()
            for alt in ["jpg", "jpeg", "png", "gif", "webp"] {
                let decoded = base.appendingPathExtension(alt)
                if FileManager.default.fileExists(atPath: decoded.path) {
                    let decodedRel = (rel as NSString).deletingPathExtension + ".\(alt)"
                    return embedMedia(relativePath: decodedRel, sourceDir: sourceDir)
                }
            }
        }

        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }

        if let imageData = ImageExporter.normalizeImageData(data),
           let mime = ImageExporter.sniffImageMIME(imageData) {
            let b64 = imageData.base64EncodedString()
            return "<img alt=\"图片\" class=\"chat-img\" loading=\"lazy\" src=\"data:\(mime);base64,\(b64)\"/>"
        }

        let b64 = data.base64EncodedString()
        switch ext {
        case "jpg", "jpeg":
            return "<img alt=\"图片\" class=\"chat-img\" loading=\"lazy\" src=\"data:image/jpeg;base64,\(b64)\"/>"
        case "png":
            return "<img alt=\"图片\" class=\"chat-img\" loading=\"lazy\" src=\"data:image/png;base64,\(b64)\"/>"
        case "gif":
            return "<img alt=\"表情\" class=\"chat-img\" loading=\"lazy\" src=\"data:image/gif;base64,\(b64)\"/>"
        case "webp":
            return "<img alt=\"图片\" class=\"chat-img\" loading=\"lazy\" src=\"data:image/webp;base64,\(b64)\"/>"
        case "dat":
            return "<p class=\"text\">[加密图片未能解密：\(escapeHTML(fileURL.lastPathComponent))]</p>"
        case "wxgf":
            return "<p class=\"text\">[WXGF 图片未能解码：\(escapeHTML(fileURL.lastPathComponent))]</p>"
        case "mp3", "m4a", "aac":
            let mime = ext == "mp3" ? "audio/mpeg" : "audio/mp4"
            return "<audio controls src=\"data:\(mime);base64,\(b64)\"></audio>"
        case "mp4", "mov":
            return "<video controls src=\"data:video/mp4;base64,\(b64)\"></video>"
        case "silk":
            return "<p class=\"text\">[语音 SILK 格式：\(escapeHTML(fileURL.lastPathComponent))，大小 \(data.count) 字节]</p>"
        default:
            return "<p class=\"text\">[附件 \(escapeHTML(fileURL.lastPathComponent))，大小 \(data.count) 字节]</p>"
        }
    }

    // MARK: - JSON parsing

    private static func parseMessages(from jsonURL: URL) throws -> [MessageRow] {
        let data = try Data(contentsOf: jsonURL)
        let root = try JSONSerialization.jsonObject(with: data)

        let rawRows: [[String: Any]]
        if let array = root as? [[String: Any]] {
            rawRows = array
        } else if let dict = root as? [String: Any] {
            if let items = dict["items"] as? [[String: Any]] { rawRows = items }
            else if let messages = dict["messages"] as? [[String: Any]] { rawRows = messages }
            else if let results = dict["results"] as? [[String: Any]] { rawRows = results }
            else { throw AppError.exportFailed("chat.json 中未找到消息列表") }
        } else {
            throw AppError.exportFailed("chat.json 格式不支持")
        }

        return rawRows.map { parseRow($0) }.filter { !$0.sender.isEmpty || !$0.content.isEmpty || !$0.mediaPaths.isEmpty }
    }

    private static func parseRow(_ row: [String: Any]) -> MessageRow {
        let nested = row["message"] as? [String: Any]
        let source = nested ?? row

        let ts = intField(source, keys: ["create_time", "timestamp"]) ?? intField(row, keys: ["create_time", "timestamp"])
        let time = stringField(row, keys: ["time", "timestamp_str"])
            ?? stringField(source, keys: ["time", "timestamp_str"])
            ?? formatTimestamp(ts)

        let sender = stringField(row, keys: ["sender_display_name", "sender", "from", "display_name"])
            ?? stringField(source, keys: ["sender_display_name", "sender"])
            ?? "未知"

        let msgType = intField(source, keys: ["msg_type", "type"]) ?? intField(row, keys: ["msg_type", "type"])
        let typeName = stringField(row, keys: ["type_name", "type"])
            ?? stringField(source, keys: ["type_name"])
            ?? typeLabel(for: msgType)

        let content = stringField(row, keys: ["snippet", "content", "text", "message", "summary"])
            ?? stringField(source, keys: ["snippet", "content", "text"])
            ?? ""

        var media = (row["media_files"] as? [String]) ?? (source["media_files"] as? [String]) ?? []
        if media.isEmpty, let array = row["media_files"] as? [Any] {
            media = array.compactMap { $0 as? String }
        }

        return MessageRow(time: time, sender: sender, type: typeName, content: content, mediaPaths: media)
    }

    private static func typeLabel(for type: Int?) -> String {
        guard let type else { return "消息" }
        switch type {
        case 1: return "文本"
        case 3: return "图片"
        case 34: return "语音"
        case 43: return "视频"
        case 47: return "表情"
        case 49: return "链接/文件"
        default: return "类型\(type)"
        }
    }

    private static func stringField(_ row: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = row[key] as? String, !value.isEmpty { return value }
            if let value = row[key] as? Int { return String(value) }
            if let nested = row[key] as? [String: Any] {
                if let text = nested["Text"] as? String { return text }
                if let text = nested["text"] as? String { return text }
                if let emoji = nested["Emoji"] as? String { return "[表情]" }
            }
        }
        return nil
    }

    private static func intField(_ row: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = row[key] as? Int { return value }
            if let value = row[key] as? Int64 { return Int(value) }
            if let value = row[key] as? Double { return Int(value) }
        }
        return nil
    }

    private static func formatTimestamp(_ ts: Int?) -> String {
        guard let ts, ts > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: date)
    }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: Date())
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
        return cleaned.isEmpty ? "聊天记录" : cleaned
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
