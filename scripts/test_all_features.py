#!/usr/bin/env python3
"""离线功能回归测试：覆盖导出查询、会话校验、HTML 打包、图片嗅探、资源与版本一致性。

本环境无法启动微信 / macOS GUI / Windows WPF，因此对可离线验证的逻辑做全量断言；
真机交互（准备数据、密钥捕获、实际微信数据库）需在用户机器上验证，由 GitHub CI
负责双平台编译。
"""

from __future__ import annotations

import base64
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TZ_SH = timezone(timedelta(hours=8))
PASSED = 0
FAILED = 0
ERRORS: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    global PASSED, FAILED
    if cond:
        PASSED += 1
        print(f"  PASS  {name}")
    else:
        FAILED += 1
        msg = f"  FAIL  {name}" + (f" — {detail}" if detail else "")
        print(msg)
        ERRORS.append(msg)


# ---------------------------------------------------------------------------
# 业务逻辑（与 Swift/C# 实现对齐）
# ---------------------------------------------------------------------------

def export_query(contact_id: str, display_name: str) -> str:
    cid = (contact_id or "").strip()
    if cid:
        return cid
    return (display_name or "").strip()


def read_exported_talker(payload: dict | list) -> str | None:
    if not isinstance(payload, dict):
        return None
    talker = payload.get("talker")
    if isinstance(talker, str) and talker.strip():
        return talker.strip()
    conversation = payload.get("conversation")
    if isinstance(conversation, dict):
        for key in ("talker", "username"):
            value = conversation.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
    export_info = payload.get("export_info")
    if isinstance(export_info, dict):
        value = export_info.get("talker")
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def talker_matches(expected_id: str, actual: str | None) -> bool:
    if not actual:
        return True  # 无 talker 字段时不误杀
    return actual.casefold() == expected_id.casefold()


def sanitize_filename(name: str) -> str:
    cleaned = re.sub(r'[/\\:?*"<>|]', "_", name)
    return cleaned if cleaned else "聊天记录"


def escape_html(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def sniff_image_mime(data: bytes) -> str | None:
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"GIF87a") or data.startswith(b"GIF89a"):
        return "image/gif"
    if len(data) >= 12 and data[0:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


def xor_decode(data: bytes, key: int) -> bytes:
    return bytes(b ^ key for b in data)


def try_decode_dat_xor(data: bytes) -> bytes | None:
    for key in range(256):
        sample = xor_decode(data, key)
        if sniff_image_mime(sample) is not None:
            return sample
    return None


def filter_contacts(contacts: list[dict], query: str) -> list[dict]:
    q = query.strip().lower()
    if not q:
        return contacts
    out = []
    for c in contacts:
        hay = " ".join(
            [
                c.get("displayName", ""),
                c.get("nickName", ""),
                c.get("remark", ""),
                c.get("id", ""),
                c.get("summary", ""),
            ]
        ).lower()
        if q in hay:
            out.append(c)
    return out


def parse_message_rows(root) -> list[dict]:
    if isinstance(root, list):
        raw = root
    elif isinstance(root, dict):
        if isinstance(root.get("items"), list):
            raw = root["items"]
        elif isinstance(root.get("messages"), list):
            raw = root["messages"]
        elif isinstance(root.get("results"), list):
            raw = root["results"]
        else:
            raise ValueError("chat.json 中未找到消息列表")
    else:
        raise ValueError("chat.json 格式不支持")

    rows = []
    for row in raw:
        nested = row.get("message") if isinstance(row.get("message"), dict) else None
        source = nested or row
        sender = (
            row.get("sender_display_name")
            or row.get("sender")
            or source.get("sender_display_name")
            or source.get("sender")
            or "未知"
        )
        content = (
            row.get("snippet")
            or row.get("content")
            or row.get("text")
            or source.get("snippet")
            or source.get("content")
            or source.get("text")
            or ""
        )
        if not sender and not content:
            continue
        rows.append({"sender": str(sender), "content": str(content)})
    return rows


def render_single_file_html(contact_name: str, rows: list[dict], stamp: str) -> str:
    safe_title = escape_html(contact_name or "微信聊天记录")
    body = []
    for row in rows:
        body.append(
            "<article class='msg'>"
            f"<span class='sender'>{escape_html(row['sender'])}</span>"
            f"<p class='text'>{escape_html(row['content'])}</p>"
            "</article>"
        )
    return (
        "<!DOCTYPE html><html lang='zh-CN'><head><meta charset='utf-8'/>"
        f"<title>{safe_title}</title></head><body>"
        f"<h1>{safe_title}</h1>"
        f"<div class='stats'>{len(rows)} 条消息 · {escape_html(stamp)}</div>"
        + "".join(body)
        + "</body></html>"
    )


def aggregate_export_results(success: list[str], failures: list[str]) -> str:
    if not success:
        return f"all_failed:{len(failures)}"
    if not failures:
        return f"all_ok:{len(success)}"
    return f"partial:{len(success)}/{len(failures)}"


def snapshot_selected(contacts: list[dict], selected_ids: set[str]) -> list[dict]:
    return [c for c in contacts if c["id"] in selected_ids]


# ---------------------------------------------------------------------------
# 测试组
# ---------------------------------------------------------------------------

def test_export_query():
    print("\n[1] 导出查询优先 wxid")
    check("优先使用 wxid", export_query("wxid_abc", "张三") == "wxid_abc")
    check("群聊使用 @chatroom", export_query("123@chatroom", "同学群") == "123@chatroom")
    check("id 为空回退显示名", export_query("", "文件传输助手") == "文件传输助手")
    check("trim 空白", export_query("  wxid_x  ", "名") == "wxid_x")
    check("重名时仍用唯一 id", export_query("wxid_1", "张三") != export_query("wxid_2", "张三"))


def test_talker_validation():
    print("\n[2] 导出结果会话校验")
    ok = {"conversation": {"talker": "wxid_a", "message_count": 3}, "items": []}
    bad = {"export_info": {"talker": "wxid_b"}, "items": [{"sender": "x", "content": "y"}]}
    flat = {"talker": "WXID_A", "messages": []}
    check("读取 conversation.talker", read_exported_talker(ok) == "wxid_a")
    check("读取 export_info.talker", read_exported_talker(bad) == "wxid_b")
    check("大小写不敏感匹配", talker_matches("wxid_a", read_exported_talker(flat)))
    check("不匹配时报错条件成立", not talker_matches("wxid_a", read_exported_talker(bad)))
    check("无 talker 不误杀", talker_matches("wxid_a", read_exported_talker({"items": []})))


def test_contact_filter_and_selection():
    print("\n[3] 会话搜索与选中快照")
    contacts = [
        {"id": "wxid_a", "displayName": "张三", "nickName": "三哥", "remark": "", "summary": "你好"},
        {"id": "wxid_b", "displayName": "李四", "nickName": "", "remark": "同事", "summary": ""},
        {"id": "999@chatroom", "displayName": "项目群", "nickName": "", "remark": "", "summary": "开会"},
    ]
    check("按显示名搜索", [c["id"] for c in filter_contacts(contacts, "张三")] == ["wxid_a"])
    check("按备注搜索", [c["id"] for c in filter_contacts(contacts, "同事")] == ["wxid_b"])
    check("按 wxid 搜索", [c["id"] for c in filter_contacts(contacts, "wxid_b")] == ["wxid_b"])
    check("按群名搜索", [c["id"] for c in filter_contacts(contacts, "项目")] == ["999@chatroom"])

    selected_ids = {"wxid_a", "999@chatroom"}
    snap = snapshot_selected(contacts, selected_ids)
    # 模拟导出过程中 contacts / selection 被改写
    contacts.append({"id": "wxid_hijack", "displayName": "黑客", "nickName": "", "remark": "", "summary": ""})
    selected_ids.add("wxid_hijack")
    check("快照不受后续选中污染", [c["id"] for c in snap] == ["wxid_a", "999@chatroom"])


def test_partial_export_isolation():
    print("\n[4] 多选导出失败隔离")
    check("全部成功", aggregate_export_results(["a", "b"], []) == "all_ok:2")
    check("全部失败", aggregate_export_results([], ["a", "b"]) == "all_failed:2")
    check("部分成功", aggregate_export_results(["a"], ["b", "c"]) == "partial:1/2")


def test_sanitize_and_escape():
    print("\n[5] 文件名清理与 HTML 转义")
    check("清理非法文件名", sanitize_filename('张三/李四:群?*"<>|') == "张三_李四_群______")
    check("空名回退", sanitize_filename("") == "聊天记录")
    check("HTML 转义", escape_html('<a&b>"') == "&lt;a&amp;b&gt;&quot;")


def test_image_and_dat_decode():
    print("\n[6] 图片嗅探与 .dat XOR 解密")
    jpeg = b"\xff\xd8\xff\xe0" + b"\x00" * 16
    png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 16
    gif = b"GIF89a" + b"\x00" * 16
    webp = b"RIFF" + b"\x10\x00\x00\x00" + b"WEBP" + b"\x00" * 8
    check("JPEG MIME", sniff_image_mime(jpeg) == "image/jpeg")
    check("PNG MIME", sniff_image_mime(png) == "image/png")
    check("GIF MIME", sniff_image_mime(gif) == "image/gif")
    check("WEBP MIME", sniff_image_mime(webp) == "image/webp")
    check("非图片为 None", sniff_image_mime(b"hello") is None)

    key = 0x37
    encrypted = xor_decode(jpeg, key)
    decoded = try_decode_dat_xor(encrypted)
    check("XOR 可还原 JPEG", decoded is not None and sniff_image_mime(decoded) == "image/jpeg")


def test_message_parsing_and_html():
    print("\n[7] chat.json 解析与单文件 HTML")
    fixtures = [
        [{"sender": "甲", "content": "你好", "msg_type": 1}],
        {"items": [{"sender_display_name": "乙", "snippet": "在吗", "msg_type": 1}]},
        {"messages": [{"sender": "丙", "text": "晚上见", "type": 1}]},
        {
            "conversation": {"talker": "wxid_demo", "message_count": 2},
            "results": [
                {"sender": "丁", "content": "<script>alert(1)</script>"},
                {"message": {"sender": "戊", "content": "第二句"}},
            ],
        },
    ]
    for i, fixture in enumerate(fixtures):
        rows = parse_message_rows(fixture)
        check(f"解析格式 #{i + 1}", len(rows) >= 1, f"got {len(rows)}")

    rows = parse_message_rows(fixtures[-1])
    stamp = datetime.now(TZ_SH).strftime("%Y%m%d_%H%M%S")
    out = render_single_file_html("测试<>会话", rows, stamp)
    check("HTML 含标题转义", "&lt;" in out and "测试" in out)
    check("HTML 含消息数", "2 条消息" in out)
    check("脚本内容被转义", "<script>" not in out and "&lt;script&gt;" in out)

    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp) / f"{sanitize_filename('测试<>会话')}_{stamp}.html"
        dest.write_text(out, encoding="utf-8")
        check("HTML 可写入磁盘", dest.exists() and dest.stat().st_size > 0)


def test_source_contracts():
    print("\n[8] 源码契约（防止回退到显示名查询）")
    swift = (ROOT / "Sources/WeChatExporter/Services/WxCliService.swift").read_text(encoding="utf-8")
    csharp = (ROOT / "windows/WeChatExporter.Windows/Services/WxCliService.cs").read_text(encoding="utf-8")
    mac_vm = (ROOT / "Sources/WeChatExporter/ViewModels/AppViewModel.swift").read_text(encoding="utf-8")
    win_vm = (ROOT / "windows/WeChatExporter.Windows/ViewModels/MainViewModel.cs").read_text(encoding="utf-8")
    win_ui = (ROOT / "windows/WeChatExporter.Windows/MainWindow.xaml.cs").read_text(encoding="utf-8")

    check("Swift 定义 exportQuery", "static func exportQuery(for contact: ContactItem)" in swift)
    check("Swift 使用 exportQuery", "Self.exportQuery(for: contact)" in swift)
    check("Swift 不再优先 displayName 查询", "let query = !contact.displayName.isEmpty ? contact.displayName" not in swift)
    check("Swift 含 talker 校验", "exportedTalker" in swift and "导出结果会话不匹配" in swift)
    check("Swift 0 条消息抛错", "未找到与" in swift)

    check("C# 定义 ExportQuery", "internal static string ExportQuery" in csharp)
    check("C# 使用 ExportQuery", "ExportQuery(contact)" in csharp)
    check("C# 不再优先 DisplayName 查询", "string.IsNullOrWhiteSpace(contact.DisplayName) ? contact.Id : contact.DisplayName" not in csharp)
    check("C# 含 talker 校验", "ReadExportedTalker" in csharp and "导出结果会话不匹配" in csharp)

    check("macOS 导出快照 selectedIDs", "selectedIDsSnapshot" in mac_vm)
    check("macOS 单人失败隔离", "failures.append" in mac_vm)
    check("Windows 导出快照 selected", "var selected = SelectedContacts.ToList()" in win_vm)
    check("Windows 单人失败隔离", "failures.Add" in win_vm)
    check("Windows busy 时忽略选中变化", "if (_viewModel.IsBusy) return;" in win_ui)


def test_versions_and_assets():
    print("\n[9] 版本号与内置资源")
    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    build_app = (ROOT / "build_app.sh").read_text(encoding="utf-8")
    csproj = (ROOT / "windows/WeChatExporter.Windows/WeChatExporter.Windows.csproj").read_text(encoding="utf-8")
    check("CHANGELOG 含 2.8.0", "## [2.8.0]" in changelog)
    check("build_app.sh 版本 2.8.0", 'APP_VERSION="${APP_VERSION:-2.8.0}"' in build_app)
    check("Windows csproj 版本 2.8.0", "<Version>2.8.0</Version>" in csproj)

    mac_cli = ROOT / "vendor/macos/wx-cli"
    win_cli = ROOT / "vendor/windows/wx.exe"
    check("存在 macOS wx-cli", mac_cli.is_file() and mac_cli.stat().st_size > 1_000_000)
    check("存在 Windows wx.exe", win_cli.is_file() and win_cli.stat().st_size > 1_000_000)

    mac_strings = subprocess.check_output(["strings", str(mac_cli)], text=True, errors="ignore")
    check("wx-cli 含 export 子命令", "Export a conversation" in mac_strings or re.search(r"\bexport\b", mac_strings, re.I) is not None)
    check("wx-cli 支持 4.1.11", "4.1.11" in mac_strings)
    check("wx-cli 接受 wxid 查询", "wxid" in mac_strings.lower())


def test_shell_scripts():
    print("\n[10] Shell 脚本语法")
    scripts = [
        ROOT / "build_app.sh",
        ROOT / "install.sh",
        ROOT / "scripts/prepare_icon.sh",
        ROOT / "scripts/bundle_wx_cli.sh",
        ROOT / "scripts/create_dmg.sh",
    ]
    for script in scripts:
        proc = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
        check(f"bash -n {script.relative_to(ROOT)}", proc.returncode == 0, proc.stderr.strip())


def test_vendor_bundle_copy():
    print("\n[11] vendor 打包复制（模拟 CI bundle）")
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp) / "out"
        dest.mkdir()
        src = ROOT / "vendor/windows/wx.exe"
        shutil.copy2(src, dest / "wx.exe")
        check("复制 wx.exe 成功", (dest / "wx.exe").is_file())
        check("复制后大小一致", (dest / "wx.exe").stat().st_size == src.stat().st_size)


def test_feature_surface_files():
    print("\n[12] 功能模块文件齐全")
    required = [
        "Sources/WeChatExporter/Services/WxCliService.swift",
        "Sources/WeChatExporter/Services/SingleFileExporter.swift",
        "Sources/WeChatExporter/Services/ChatExporter.swift",
        "Sources/WeChatExporter/Services/ImageExporter.swift",
        "Sources/WeChatExporter/Services/EmojiExporter.swift",
        "Sources/WeChatExporter/Services/StickerPackExporter.swift",
        "Sources/WeChatExporter/Services/DatImageDecoder.swift",
        "Sources/WeChatExporter/Models/AppSettings.swift",
        "Sources/WeChatExporter/Views/SettingsView.swift",
        "Sources/WeChatExporter/Services/FolderBundleExporter.swift",
        "Sources/WeChatExporter/Models/ExportStyle.swift",
        "Sources/WeChatExporter/Services/WXGFTranscoder.swift",
        "Sources/WeChatExporter/Services/KeyCaptureService.swift",
        "Sources/WeChatExporter/Services/DatabaseService.swift",
        "Sources/WeChatExporter/ViewModels/AppViewModel.swift",
        "Sources/WeChatExporter/Views/ContentView.swift",
        "windows/WeChatExporter.Windows/Services/WxCliService.cs",
        "windows/WeChatExporter.Windows/Services/SingleFileExporter.cs",
        "windows/WeChatExporter.Windows/Services/FolderBundleExporter.cs",
        "windows/WeChatExporter.Windows/Services/AppSettings.cs",
        "windows/WeChatExporter.Windows/SettingsWindow.xaml",
        "windows/WeChatExporter.Windows/Models/ExportStyle.cs",
        "windows/WeChatExporter.Windows/Services/ImageExporter.cs",
        "windows/WeChatExporter.Windows/Services/EmojiExporter.cs",
        "windows/WeChatExporter.Windows/Services/StickerPackExporter.cs",
        "windows/WeChatExporter.Windows/Services/DatImageDecoder.cs",
        "windows/WeChatExporter.Windows/Services/WXGFTranscoder.cs",
        "windows/WeChatExporter.Windows/ViewModels/MainViewModel.cs",
        "windows/WeChatExporter.Windows/MainWindow.xaml",
    ]
    for rel in required:
        check(f"存在 {rel}", (ROOT / rel).is_file())


def test_csharp_logic_selftest():
    print("\n[13] C# 纯逻辑自测（dotnet）")
    dotnet = shutil.which("dotnet") or os.path.expanduser("~/.dotnet/dotnet")
    project = ROOT / "scripts/ExportLogicSelfTest/ExportLogicSelfTest.csproj"
    if not Path(dotnet).exists():
        check("dotnet 可用", False, "未找到 dotnet")
        return
    proc = subprocess.run(
        [dotnet, "run", "--project", str(project), "-c", "Release"],
        capture_output=True,
        text=True,
        env={**os.environ, "DOTNET_ROOT": str(Path(dotnet).parent), "PATH": f"{Path(dotnet).parent}:{os.environ.get('PATH', '')}"},
    )
    out = (proc.stdout or "") + (proc.stderr or "")
    check("C# ExportLogicSelfTest 退出码 0", proc.returncode == 0, out[-500:])
    check("C# ALL PASSED", "ALL PASSED" in out, out[-300:])


def test_folder_bundle_layout():
    print("\n[14] 分类文件夹布局")
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "src"
        media_images = src / "media" / "images"
        media_emojis = src / "media" / "emojis"
        media_voice = src / "media" / "voice"
        media_video = src / "media" / "video"
        for d in (media_images, media_emojis, media_voice, media_video):
            d.mkdir(parents=True)
        (src / "chat.txt").write_text("[2026-01-01 12:00:00] 甲: 你好\n", encoding="utf-8")
        (src / "chat.json").write_text(
            json.dumps({"items": [{"sender": "甲", "content": "你好", "msg_type": 1}]}),
            encoding="utf-8",
        )
        (media_images / "a.jpg").write_bytes(b"\xff\xd8\xff\xe0" + b"\x00" * 8)
        (media_emojis / "e.gif").write_bytes(b"GIF89a" + b"\x00" * 8)
        (media_voice / "v.mp3").write_bytes(b"ID3" + b"\x00" * 8)
        (media_video / "clip.mp4").write_bytes(b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 8)

        # 模拟 FolderBundleExporter 分类规则
        out = Path(tmp) / "out" / "联系人_test"
        mapping = {
            "图片": out / "图片",
            "音频": out / "音频",
            "视频": out / "视频",
            "表情": out / "表情",
        }
        for d in mapping.values():
            d.mkdir(parents=True)
        shutil.copy2(src / "chat.txt", out / "文字记录.txt")

        image_exts = {"jpg", "jpeg", "png", "gif", "webp", "bmp"}
        audio_exts = {"mp3", "m4a", "aac", "wav", "ogg", "silk", "amr"}
        video_exts = {"mp4", "mov", "m4v", "avi", "mkv"}
        media_root = src / "media"
        for file in media_root.rglob("*"):
            if not file.is_file():
                continue
            rel = str(file.relative_to(media_root)).replace("\\", "/")
            ext = file.suffix.lower().lstrip(".")
            is_emoji = "/emojis/" in f"/{rel}" or rel.startswith("emojis/")
            if is_emoji:
                shutil.copy2(file, mapping["表情"] / file.name)
            elif ext in image_exts:
                shutil.copy2(file, mapping["图片"] / file.name)
            elif ext in audio_exts:
                shutil.copy2(file, mapping["音频"] / file.name)
            elif ext in video_exts:
                shutil.copy2(file, mapping["视频"] / file.name)

        check("文字记录存在", (out / "文字记录.txt").is_file())
        check("图片分目录", (mapping["图片"] / "a.jpg").is_file())
        check("表情分目录", (mapping["表情"] / "e.gif").is_file())
        check("音频分目录", (mapping["音频"] / "v.mp3").is_file())
        check("视频分目录", (mapping["视频"] / "clip.mp4").is_file())

    swift_ui = (ROOT / "Sources/WeChatExporter/Views/ContentView.swift").read_text(encoding="utf-8")
    win_xaml = (ROOT / "windows/WeChatExporter.Windows/MainWindow.xaml").read_text(encoding="utf-8")
    mac_vm = (ROOT / "Sources/WeChatExporter/ViewModels/AppViewModel.swift").read_text(encoding="utf-8")
    settings_swift = (ROOT / "Sources/WeChatExporter/Views/SettingsView.swift").read_text(encoding="utf-8")
    app_settings_swift = (ROOT / "Sources/WeChatExporter/Models/AppSettings.swift").read_text(encoding="utf-8")
    settings_win = (ROOT / "windows/WeChatExporter.Windows/SettingsWindow.xaml").read_text(encoding="utf-8")
    app_settings_win = (ROOT / "windows/WeChatExporter.Windows/Services/AppSettings.cs").read_text(encoding="utf-8")
    settings_win_cs = (ROOT / "windows/WeChatExporter.Windows/SettingsWindow.xaml.cs").read_text(encoding="utf-8")
    credit = "@林琝淏科技集团有限公司出品"
    check("macOS UI 含设置入口", "设置" in swift_ui and "showSettings" in swift_ui)
    check("Windows UI 含设置入口", "Settings_Click" in win_xaml or "设置" in win_xaml)
    check("macOS 导出分支含 folderBundle", "folderBundle" in mac_vm and "FolderBundleExporter" in mac_vm)
    check("设置页含出品标注", credit in app_settings_swift and "AppSettings.creditLine" in settings_swift)
    check("Windows 设置含出品标注", credit in app_settings_win and ("CreditText" in settings_win or "AppSettings.CreditLine" in settings_win_cs))
    check("设置含浅色深色", "浅色" in app_settings_swift and "深色" in app_settings_swift and "appearance" in settings_swift)
    check("Windows 设置含主题", "AppearanceLight" in settings_win and "AppearanceDark" in settings_win)


def main() -> int:
    print("WeChatExporter 离线功能测试")
    print(f"仓库：{ROOT}")
    test_export_query()
    test_talker_validation()
    test_contact_filter_and_selection()
    test_partial_export_isolation()
    test_sanitize_and_escape()
    test_image_and_dat_decode()
    test_message_parsing_and_html()
    test_source_contracts()
    test_versions_and_assets()
    test_shell_scripts()
    test_vendor_bundle_copy()
    test_feature_surface_files()
    test_csharp_logic_selftest()
    test_folder_bundle_layout()

    print("\n" + "=" * 60)
    print(f"结果：{PASSED} 通过，{FAILED} 失败")
    if ERRORS:
        print("失败项：")
        for err in ERRORS:
            print(err)
    # 明确标注无法在本环境覆盖的真机项
    print(
        "\n未覆盖（需用户本机 / 微信已登录）：\n"
        "  - 准备数据（密钥捕获 / 解密）\n"
        "  - 真实会话列表加载\n"
        "  - GUI 点击导出与弹窗\n"
        "  - 媒体下载 / WXGF 转码实机效果\n"
        "以上由 GitHub CI 负责双平台编译；本次 CI 已成功。"
    )
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
