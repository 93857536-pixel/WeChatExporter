using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Text.Json;

namespace WeChatExporter.Services;

/// <summary>
/// 导出目录索引导航页：递归扫描导出目录，生成 index.html
/// （文件列表 + 全文检索框，内嵌文本数据可离线打开）。
/// </summary>
public static class ExportIndexBuilder
{
    private static readonly HashSet<string> MediaExts =
        new(StringComparer.OrdinalIgnoreCase)
        { "png", "jpg", "jpeg", "gif", "webp", "silk", "pcm", "wav", "mp3", "m4a", "mp4", "mov" };

    private const int PerFileLimit = 200_000;

    /// <summary>生成索引导航页，返回 index.html 路径；失败返回 null。</summary>
    public static string? WriteIndex(string baseDir, Action<string>? log)
    {
        var htmlFiles = new List<string>();
        var textFiles = new List<string>();
        var mediaCount = 0;
        long mediaBytes = 0;

        foreach (var file in Directory.EnumerateFiles(baseDir, "*", SearchOption.AllDirectories))
        {
            var name = Path.GetFileName(file);
            if (name.StartsWith(".") || name.StartsWith("$")) continue;
            var ext = Path.GetExtension(name).TrimStart('.').ToLowerInvariant();
            if (ext == "html")
            {
                if (name != "index.html") htmlFiles.Add(Relative(baseDir, file));
            }
            else if (ext is "txt" or "json" or "csv" or "md")
            {
                textFiles.Add(Relative(baseDir, file));
            }
            else if (MediaExts.Contains(ext))
            {
                mediaCount++;
                try { mediaBytes += new FileInfo(file).Length; } catch { /* ignore */ }
            }
        }
        htmlFiles.Sort(StringComparer.OrdinalIgnoreCase);
        textFiles.Sort(StringComparer.OrdinalIgnoreCase);

        // 内嵌文本搜索数据（单文件上限 200K 字符，超出截断）
        var textData = new List<Dictionary<string, object?>>();
        foreach (var rel in textFiles)
        {
            var full = Path.Combine(baseDir, rel);
            string raw;
            try { raw = File.ReadAllText(full); } catch { continue; }
            var truncated = raw.Length > PerFileLimit;
            textData.Add(new Dictionary<string, object?>
            {
                ["name"] = rel,
                ["truncated"] = truncated,
                ["content"] = truncated ? raw[..PerFileLimit] : raw,
            });
        }
        string embedded;
        try { embedded = JsonSerializer.Serialize(textData); }
        catch { embedded = "[]"; }

        var sb = new StringBuilder();
        sb.Append("<!DOCTYPE html>\n<html lang=\"zh-CN\"><head><meta charset=\"utf-8\">");
        sb.Append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">");
        sb.Append("<title>微信聊天记录导出 · 目录</title><style>").Append(Styles).Append("</style></head><body>");
        sb.Append(Watermark.HtmlOverlay());
        sb.Append("<header><h1>📁 导出目录</h1>");
        sb.Append($"<p class=\"sub\">单文件 HTML {htmlFiles.Count} 份　·　文本 {textFiles.Count} 份　·　媒体 {mediaCount} 个（{FormatBytes(mediaBytes)}）</p></header>");
        sb.Append("<div class=\"searchbox\"><input id=\"q\" type=\"search\" placeholder=\"全文检索（关键词不区分大小写，搜索内嵌文本文件）\" autocomplete=\"off\"><span id=\"hitcount\"></span></div>");
        sb.Append("<div id=\"results\"></div>");

        if (htmlFiles.Count > 0)
        {
            sb.Append("<section><h2>单文件 HTML / 统计报告</h2>");
            foreach (var rel in htmlFiles)
            {
                var isStats = rel.Contains("统计");
                sb.Append($"<a class=\"file-row\" href=\"{Uri.EscapeDataString(rel)}\"><span class=\"ficon\">{(isStats ? "📊" : "📄")}</span><span class=\"fname\">{HtmlEscape(rel)}</span></a>\n");
            }
            sb.Append("</section>");
        }

        sb.Append("<footer>由 WeChatExporter 本地生成 · 检索数据已内嵌，页面可离线打开</footer>");
        sb.Append("<script>const TEXTS=").Append(embedded);
        sb.Append("""
            ;const q=document.getElementById('q'),rs=document.getElementById('results'),hc=document.getElementById('hitcount');
            q.addEventListener('input',()=>{
              const kw=q.value.trim().toLowerCase();rs.innerHTML='';
              if(!kw){hc.textContent='';return;}
              let hits=0;
              const frag=document.createDocumentFragment();
              for(const t of TEXTS){
                const lines=t.content.split('\n');const matches=[];
                for(let i=0;i<lines.length&&matches.length<3;i++){if(lines[i].toLowerCase().includes(kw)){matches.push((i+1)+': '+lines[i].trim().slice(0,200));}}
                if(matches.length>0){
                  hits+=1;
                  const d=document.createElement('div');d.className='hit';
                  const a=document.createElement('a');a.href=t.name;a.textContent='📄 '+t.name+(t.truncated?'（已截断）':'');
                  const p=document.createElement('pre');p.textContent=matches.join('\n');
                  d.appendChild(a);d.appendChild(p);frag.appendChild(d);
                }
              }
              hc.textContent=hits>0?hits+' 个文件命中':'无命中';
              rs.appendChild(frag);
            });
            </script>
            """);
        sb.Append(Watermark.HtmlFooter());
        sb.Append("</body></html>");

        var outPath = Path.Combine(baseDir, "index.html");
        try
        {
            File.WriteAllText(outPath, sb.ToString(), new UTF8Encoding(false));
            log?.Invoke("目录导航页已生成：index.html");
            return outPath;
        }
        catch (Exception ex)
        {
            log?.Invoke($"目录导航页写入失败：{ex.Message}");
            return null;
        }
    }

    private static string Relative(string baseDir, string full)
        => full[baseDir.Length..].TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

    private static string HtmlEscape(string s) => WebUtility.HtmlEncode(s);

    private static string FormatBytes(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB"];
        double v = bytes;
        var i = 0;
        while (v >= 1024 && i < units.Length - 1) { v /= 1024; i++; }
        return $"{v:0.#} {units[i]}";
    }

    private const string Styles = """
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
    .hit { margin-bottom: 14px; padding: 12px 14px; border-radius: 10px; background: var(--card); border: 1px solid rgba(123,97,255,.3); }
    .hit a { color: var(--cyan); font-size: 13px; text-decoration: none; }
    .hit pre { margin: 8px 0 0; font-family: ui-monospace, monospace; font-size: 12px; color: var(--sub); white-space: pre-wrap; word-break: break-all; }
    footer { text-align: center; color: var(--sub); font-size: 12px; margin-top: 20px; }
    """;
}
