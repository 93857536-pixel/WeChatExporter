import Foundation

/// 导出目录索引导航页：递归扫描导出目录，生成 index.html
/// - 文件列表（分组：单文件 HTML / 统计报告 / 文本 / 媒体）
/// - 全文检索框：内嵌各文本文件内容（单文件字符上限 200KB，超出截断），
///   关键词不区分大小写匹配，展示命中文件与前 3 条匹配行
enum ExportIndexBuilder {
    /// 生成索引导航页，返回 index.html 路径
    @discardableResult
    static func writeIndex(
        into base: URL,
        log: @escaping (String) -> Void
    ) -> URL? {
        let fm = FileManager.default
        var htmlFiles: [URL] = []
        var textFiles: [URL] = []
        var mediaCount = 0
        var mediaBytes = 0

        if let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .totalFileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir { continue }
                let ext = url.pathExtension.lowercased()
                switch ext {
                case "html":
                    if url.lastPathComponent != "index.html" { htmlFiles.append(url) }
                case "txt", "json", "csv", "md":
                    textFiles.append(url)
                default:
                    if ["png", "jpg", "jpeg", "gif", "webp", "silk", "pcm", "wav", "mp3", "m4a", "mp4", "mov"].contains(ext) {
                        mediaCount += 1
                        mediaBytes += (try? url.resourceValues(forKeys: [.totalFileSizeKey]).totalFileSize) ?? 0
                    }
                }
            }
        }
        htmlFiles.sort { $0.lastPathComponent < $1.lastPathComponent }
        textFiles.sort { $0.lastPathComponent < $1.lastPathComponent }

        // 内嵌文本搜索数据（单文件上限 200_000 字符，超出截断）
        let perFileLimit = 200_000
        var textData: [[String: Any]] = []
        for f in textFiles {
            guard let raw = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let rel = String(f.path.replacingOccurrences(of: base.path + "/", with: ""))
            let truncated = raw.count > perFileLimit
            let content = truncated ? String(raw.prefix(perFileLimit)) : raw
            textData.append([
                "name": rel,
                "truncated": truncated,
                "content": content,
            ])
        }
        let embedded = (try? JSONSerialization.data(withJSONObject: textData)) ?? Data("[]".utf8)

        var html = ""
        html += "<!DOCTYPE html>\n<html lang=\"zh-CN\"><head><meta charset=\"utf-8\">"
        html += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        html += "<title>微信聊天记录导出 · 目录</title><style>" + styles + "</style></head><body>"
        html += "<header><h1>📁 导出目录</h1>"
        html += "<p class=\"sub\">单文件 HTML \(htmlFiles.count) 份　·　文本 \(textFiles.count) 份　·　媒体 \(mediaCount) 个（\(ByteCountFormatter.string(fromByteCount: Int64(mediaBytes), countStyle: .file))）</p></header>"

        // 搜索框
        html += "<div class=\"searchbox\"><input id=\"q\" type=\"search\" placeholder=\"全文检索（关键词不区分大小写，搜索内嵌文本文件）\" autocomplete=\"off\"><span id=\"hitcount\"></span></div>"
        html += "<div id=\"results\"></div>"

        // 文件列表
        if !htmlFiles.isEmpty {
            html += "<section><h2>单文件 HTML / 统计报告</h2>"
            for f in htmlFiles {
                let rel = String(f.path.replacingOccurrences(of: base.path + "/", with: ""))
                let isStats = rel.contains("统计")
                html += rowLink(rel, isStats ? "📊" : "📄", f)
            }
            html += "</section>"
        }
        html += "<footer>由 WeChatExporter 本地生成 · 检索数据已内嵌，页面可离线打开</footer>"
        html += "<script>const TEXTS=" + (String(data: embedded, encoding: .utf8) ?? "[]")
        html += """
            ;const q=document.getElementById('q'),rs=document.getElementById('results'),hc=document.getElementById('hitcount');
            q.addEventListener('input',()=>{
              const kw=q.value.trim().toLowerCase();rs.innerHTML='';
              if(!kw){hc.textContent='';return;}
              let hits=0;
              const frag=document.createDocumentFragment();
              for(const t of TEXTS){
                const lines=t.content.split('\\n');const matches=[];
                for(let i=0;i<lines.length&&matches.length<3;i++){if(lines[i].toLowerCase().includes(kw)){matches.push((i+1)+': '+lines[i].trim().slice(0,200));}}
                if(matches.length>0){
                  hits+=1;
                  const d=document.createElement('div');d.className='hit';
                  const a=document.createElement('a');a.href=t.name;a.textContent='📄 '+t.name+(t.truncated?'（已截断）':'');
                  const p=document.createElement('pre');p.textContent=matches.join('\\n');
                  d.appendChild(a);d.appendChild(p);frag.appendChild(d);
                }
              }
              hc.textContent=hits>0?hits+' 个文件命中':'无命中';
              rs.appendChild(frag);
            });
            </script>
            </body></html>
        """

        let outURL = base.appendingPathComponent("index.html")
        do {
            try html.data(using: .utf8)?.write(to: outURL)
            log("目录导航页已生成：index.html")
            return outURL
        } catch {
            log("目录导航页写入失败：\(error.localizedDescription)")
            return nil
        }
    }

    private static func rowLink(_ name: String, _ icon: String, _ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.totalFileSizeKey]).totalFileSize) ?? 0
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return """
        <a class="file-row" href="\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)"><span class="ficon">\(icon)</span><span class="fname">\(name)</span><span class="fsize">\(sizeStr)</span></a>
        """
    }

    private static let styles = """
    :root { --bg: #0b1026; --card: rgba(255,255,255,0.05); --cyan: #00f5ff; --purple: #7b61ff; --text: #f0f8ff; --sub: #9aa7c7; }
    * { box-sizing: border-box; }
    body { margin: 0; padding: 32px 16px; background: radial-gradient(1200px 600px at 50% -100px, #1b2a5e 0%, var(--bg) 60%); color: var(--text); font-family: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif; }
    header, section, .searchbox, #results { max-width: 860px; margin: 0 auto; }
    header { text-align: center; margin-bottom: 20px; }
    h1 { font-size: 24px; margin: 0 0 8px; }
    .sub { color: var(--sub); font-size: 13px; }
    .searchbox { display: flex; gap: 10px; align-items: center; margin-bottom: 18px; }
    .searchbox input { flex: 1; padding: 12px 14px; border-radius: 12px; border: 1px solid rgba(0,245,255,.25); background: var(--card); color: var(--text); font-size: 14px; outline: none; }
    .searchbox input:focus { border-color: var(--cyan); }
    #hitcount { color: var(--sub); font-size: 12px; white-space: nowrap; }
    section { background: var(--card); border: 1px solid rgba(0,245,255,.14); border-radius: 14px; padding: 18px; margin-bottom: 18px; }
    h2 { font-size: 15px; margin: 0 0 12px; color: var(--cyan); }
    .file-row { display: flex; align-items: center; gap: 10px; padding: 10px 12px; border-radius: 10px; color: var(--text); text-decoration: none; font-size: 13px; }
    .file-row:hover { background: rgba(0,245,255,.08); }
    .ficon { color: var(--cyan); width: 18px; }
    .fname { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .fsize { color: var(--sub); font-size: 12px; }
    .hit { margin-bottom: 14px; padding: 12px 14px; border-radius: 10px; background: var(--card); border: 1px solid rgba(123,97,255,.3); }
    .hit a { color: var(--cyan); font-size: 13px; text-decoration: none; }
    .hit pre { margin: 8px 0 0; font-family: ui-monospace, monospace; font-size: 12px; color: var(--sub); white-space: pre-wrap; word-break: break-all; }
    footer { text-align: center; color: var(--sub); font-size: 12px; margin-top: 20px; }
    """
}
