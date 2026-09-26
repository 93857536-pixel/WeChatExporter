//! 单文件 HTML 导出（与 macOS `SingleFileExporter.swift` 同款「深空霓虹 HUD」主题）
//! Linux 后端为文本优先：媒体内嵌默认关闭（无 media/ 目录），生成「纯文字版」自包含 HTML。

use crate::core::models::{self, Message};
use crate::core::watermark::Watermark;
use crate::core::{util, Result};
use std::path::{Path, PathBuf};

/// 从已导出的 chat.json 生成单文件 HTML，返回 HTML 路径
pub fn write_html(
    source_dir: &Path,
    contact_name: &str,
    dest_dir: &Path,
    wm: &Watermark,
) -> Result<PathBuf> {
    let json_url = source_dir.join("chat.json");
    let json = std::fs::read_to_string(&json_url)
        .map_err(|_| crate::core::err("未找到 chat.json，无法生成单文件导出"))?;
    let messages: Vec<Message> =
        serde_json::from_str(&json).map_err(|_| crate::core::err("chat.json 格式不支持"))?;
    if messages.is_empty() {
        return Err(crate::core::err("聊天记录为空，无法生成单文件导出"));
    }

    let safe_name = models::sanitize_filename(contact_name);
    let stamp = util::file_stamp();
    let out_url = dest_dir.join(format!("{safe_name}_{stamp}.html"));

    let title = models::escape_html(contact_name);
    let mut body = String::new();
    for msg in &messages {
        body.push_str(&render_message(msg));
    }

    let html = format!(
        "<!DOCTYPE html>\n<html lang=\"zh-CN\">\n<head>\n  <meta charset=\"utf-8\"/>\n  \
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"/>\n  \
         <title>{title}</title>\n  <style>\n{EXPORT_STYLES}\n  </style>\n</head>\n<body>\n  \
         {overlay}\n  <div class=\"bg-scene\" aria-hidden=\"true\">\n    \
         <div class=\"aurora aurora-a\"></div>\n    <div class=\"aurora aurora-b\"></div>\n    \
         <div class=\"aurora aurora-c\"></div>\n    <div class=\"grid-floor\"></div>\n  </div>\n  \
         <header>\n    <div class=\"header-glow\"></div>\n    \
         <p class=\"eyebrow\">WeChatExporter · 单文件导出</p>\n    <h1>{title}</h1>\n    \
         <div class=\"stats\">\n      <span class=\"pill pill-cyan\">{n} 条消息</span>\n      \
         <span class=\"pill pill-purple\">纯文字版</span>\n      \
         <span class=\"pill pill-muted\">{stamp}</span>\n    </div>\n  </header>\n  <main>\n{body}\n  </main>\n  \
         <footer>\n    <span class=\"footer-brand\">WeChatExporter</span>\n    <span class=\"footer-dot\">·</span>\n    \
         <span>深空霓虹主题 · 浏览器离线可阅</span>\n    {footer}\n  </footer>\n</body>\n</html>\n",
        title = title,
        overlay = wm.html_overlay(false),
        n = messages.len(),
        stamp = stamp,
        body = body,
        footer = wm.html_footer(),
    );

    std::fs::create_dir_all(dest_dir)
        .map_err(|e| crate::core::err(format!("创建目录失败：{e}")))?;
    std::fs::write(&out_url, html).map_err(|e| crate::core::err(format!("写 HTML 失败：{e}")))?;
    Ok(out_url)
}

fn render_message(msg: &Message) -> String {
    let content = models::escape_html(&msg.content);
    let show_text = !content.is_empty()
        && content != "[图片]"
        && content != "[语音]"
        && content != "[视频]"
        && content != "[表情]";
    let text_block = if show_text {
        format!("<div class=\"text\">{content}</div>")
    } else {
        String::new()
    };
    format!(
        "<article class=\"msg\">\n  <div class=\"meta\">\n    \
         <span class=\"sender\">{}</span>\n    <span class=\"type\">{}</span>\n    \
         <span class=\"time\">{}</span>\n  </div>\n  {}\n</article>\n",
        models::escape_html(&msg.sender),
        models::escape_html(&msg.type_name),
        models::escape_html(&msg.time),
        text_block,
    )
}

/// 与 DMG 安装界面一致的深空霓虹 HUD 样式（青 #00f5ff · 紫 #7b61ff · 品红 #ff4dd2）
const EXPORT_STYLES: &str = r#"
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
      font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Segoe UI", "Noto Sans CJK SC", sans-serif;
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
    .aurora-a { width: 420px; height: 180px; top: -40px; left: 12%; background: radial-gradient(circle, rgba(0,180,255,0.55), transparent 70%); }
    .aurora-b { width: 380px; height: 160px; top: 60px; right: 8%; background: radial-gradient(circle, rgba(140,60,255,0.5), transparent 70%); animation-delay: -6s; }
    .aurora-c { width: 500px; height: 200px; bottom: 18%; left: 28%; background: radial-gradient(circle, rgba(255,60,200,0.35), transparent 70%); animation-delay: -12s; }
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
    .pill-cyan { color: var(--cyan); background: rgba(0,245,255,0.1); border-color: rgba(0,245,255,0.35); box-shadow: 0 0 16px rgba(0,245,255,0.18); }
    .pill-purple { color: #c4b5ff; background: rgba(123,97,255,0.14); border-color: rgba(123,97,255,0.38); box-shadow: 0 0 16px rgba(123,97,255,0.18); }
    .pill-muted { color: var(--subtext); background: rgba(140,170,210,0.08); border-color: rgba(140,170,210,0.22); }
    main { max-width: 880px; margin: 0 auto; padding: 28px 16px 56px; }
    .msg {
      position: relative;
      background: var(--glass);
      backdrop-filter: blur(14px) saturate(130%);
      -webkit-backdrop-filter: blur(14px) saturate(130%);
      border: 1px solid rgba(123,97,255,0.28);
      border-radius: 16px;
      padding: 16px 18px 18px;
      margin-bottom: 14px;
      box-shadow: 0 8px 32px rgba(0,0,0,0.32), inset 0 1px 0 rgba(255,255,255,0.05), 0 0 24px rgba(123,97,255,0.08);
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
      box-shadow: 0 10px 36px rgba(0,0,0,0.38), 0 0 28px rgba(0,245,255,0.12), inset 0 1px 0 rgba(255,255,255,0.07);
      transform: translateY(-1px);
    }
    .meta { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin-bottom: 10px; font-size: 12px; }
    .sender { font-weight: 600; color: var(--cyan); text-shadow: 0 0 10px rgba(0,245,255,0.45); }
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
    .time { color: var(--subtext); margin-left: auto; font-variant-numeric: tabular-nums; }
    .text { white-space: pre-wrap; word-break: break-word; line-height: 1.65; color: rgba(240,248,255,0.94); }
    footer {
      text-align: center;
      color: var(--subtext);
      font-size: 12px;
      padding: 28px 16px 36px;
      border-top: 1px solid rgba(123,97,255,0.15);
      background: linear-gradient(180deg, transparent, rgba(8,14,36,0.55));
    }
    .footer-brand { color: var(--cyan); font-weight: 600; text-shadow: 0 0 10px rgba(0,245,255,0.35); }
    .footer-dot { margin: 0 8px; opacity: 0.5; }
    @media (max-width: 640px) {
      header { padding: 24px 16px 22px; }
      .time { margin-left: 0; width: 100%; }
      .msg { padding: 14px 14px 16px; }
    }
"#;
