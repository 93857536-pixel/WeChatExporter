//! 端到端集成测试：用合成「已解密 SQLite 目录」验证核心导出管线与 macOS ChatExporter 同口径。

use md5::{Digest, Md5};
use rusqlite::Connection;
use std::path::Path;
use wechat_exporter_core::core::{self, models::ContactItem};

fn md5_hex(s: &str) -> String {
    format!("{:x}", Md5::digest(s.as_bytes()))
}

/// 构造一个合成解密目录：contact.db / session.db / message_0.db（含 Msg_<md5> 表 + Name2Id）
fn build_decrypted_dir(root: &Path) {
    std::fs::create_dir_all(root.join("contact")).unwrap();
    std::fs::create_dir_all(root.join("session")).unwrap();
    std::fs::create_dir_all(root.join("message")).unwrap();

    // contact.db
    let c = Connection::open(root.join("contact/contact.db")).unwrap();
    c.execute_batch("CREATE TABLE contact(username TEXT, nick_name TEXT, remark TEXT);")
        .unwrap();
    c.execute("INSERT INTO contact VALUES('wxid_alice','Alice','')", [])
        .unwrap();
    c.execute("INSERT INTO contact VALUES('wxid_bob','Bob','鲍勃')", [])
        .unwrap();

    // session.db
    let s = Connection::open(root.join("session/session.db")).unwrap();
    s.execute_batch(
        "CREATE TABLE SessionTable(username TEXT, type INTEGER, summary TEXT, last_timestamp INTEGER, sort_timestamp INTEGER);",
    )
    .unwrap();
    s.execute(
        "INSERT INTO SessionTable VALUES('wxid_alice',0,'你好',200,200)",
        [],
    )
    .unwrap();
    s.execute(
        "INSERT INTO SessionTable VALUES('room1@chatroom',2,'群聊摘要',300,300)",
        [],
    )
    .unwrap();
    s.execute(
        "INSERT INTO SessionTable VALUES('gh_offical',1,'公众号',400,400)",
        [],
    )
    .unwrap();

    // message_0.db
    let m = Connection::open(root.join("message/message_0.db")).unwrap();
    let ta = md5_hex("wxid_alice");
    let tr = md5_hex("room1@chatroom");
    m.execute_batch(&format!(
        "CREATE TABLE Name2Id(rowid INTEGER PRIMARY KEY, user_name TEXT);
         CREATE TABLE \"Msg_{ta}\"(local_type INTEGER, create_time INTEGER, real_sender_id INTEGER, message_content TEXT);
         CREATE TABLE \"Msg_{tr}\"(local_type INTEGER, create_time INTEGER, real_sender_id INTEGER, message_content TEXT);"
    ))
    .unwrap();
    m.execute("INSERT INTO Name2Id VALUES(1,'wxid_alice')", [])
        .unwrap();
    m.execute("INSERT INTO Name2Id VALUES(2,'wxid_bob')", [])
        .unwrap();
    m.execute(
        &format!("INSERT INTO \"Msg_{ta}\" VALUES(1,100,1,'你好呀')"),
        [],
    )
    .unwrap();
    m.execute(
        &format!("INSERT INTO \"Msg_{ta}\" VALUES(1,200,2,'在吗？今晚一起吃饭')"),
        [],
    )
    .unwrap();
    m.execute(&format!("INSERT INTO \"Msg_{ta}\" VALUES(3,300,1,'')"), [])
        .unwrap();
    m.execute(&format!("INSERT INTO \"Msg_{tr}\" VALUES(1,400,1,'大家早上好')"), [])
        .unwrap();
    // 加入含日期/时间的消息，让日历提取器能捕获事件
    let msg_ts_base: i64 = 1_704_844_800; // 2024-01-10 08:00 上海
    m.execute(
        &format!(
            "INSERT INTO \"Msg_{ta}\" VALUES(1,{},{},\"明天上午9点见\")",
            msg_ts_base + 86400 * 10, // 2024-01-20
            2
        ),
        [],
    )
    .unwrap();
    m.execute(
        &format!(
            "INSERT INTO \"Msg_{tr}\" VALUES(1,{},{},\"2024-03-15 下午3点开会\")",
            msg_ts_base + 86400 * 15, // 2024-01-25
            1
        ),
        [],
    )
    .unwrap();
}

#[test]
fn full_pipeline_end_to_end() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    // 隔离设置，避免写真实 ~/.config
    std::env::set_var(
        "WCE_SETTINGS",
        root.join("settings.json").to_string_lossy().as_ref(),
    );

    let decrypted = root.join("decrypted");
    build_decrypted_dir(&decrypted);
    let out = root.join("export");

    // 1. 加载会话（与 macOS ContactStore 同口径）
    let contacts = core::contact_store::load_contacts(&decrypted).unwrap();
    // gh_offical 无 Msg 表应被过滤；wxid_alice + room1 保留
    assert_eq!(contacts.len(), 2);
    let alice = contacts.iter().find(|c| c.id == "wxid_alice").unwrap();
    assert_eq!(alice.display_name, "Alice"); // 备注空 → 用昵称 Alice
    let room = contacts.iter().find(|c| c.id == "room1@chatroom").unwrap();
    assert_eq!(room.kind, core::models::ContactKind::Group);

    // 2. 单会话导出（与 macOS ChatExporter 同口径）
    let contact_dir = out.join("alice_dir");
    let count = core::chat_exporter::export(alice, &decrypted, &contact_dir).unwrap();
    assert_eq!(count, 4); // 原 3 条 + 1 条含日期消息
    let txt = std::fs::read_to_string(contact_dir.join("chat.txt")).unwrap();
    assert!(txt.contains("微信聊天记录: Alice (wxid_alice)"));
    assert!(txt.contains("[图片]")); // 媒体消息折叠
    assert!(txt.contains("鲍勃")); // 备注优先
    let json = std::fs::read_to_string(contact_dir.join("chat.json")).unwrap();
    let msgs: Vec<core::models::Message> = serde_json::from_str(&json).unwrap();
    assert_eq!(msgs.len(), 4); // 原 3 条 + 2 条含日期的消息
    assert_eq!(msgs[0].msg_type, 1);
    assert_eq!(msgs[0].sender, "Alice");
    assert_eq!(msgs[1].sender, "鲍勃");

    // 3. 完整管线（含单文件 HTML / 统计 / 索引 / 报告 / 水印）
    let settings = core::settings::Settings::default();
    let mut log = |m: String| eprintln!("{m}");
    let summary =
        core::pipeline::export_selected(&decrypted, &out, &contacts, &settings, &mut log).unwrap();
    assert_eq!(summary.contacts, 2);
    assert_eq!(summary.total_messages, 6); // 原 4 条 + 2 条含日期消息

    // 产物断言（年度报报告年份取决于消息时间戳，这里不硬编码具体年份）
    assert!(out.join("wce-search.sqlite").exists());
    assert!(out.join("index.html").exists());
    // 至少有一份年度报告（可能由最新年份或 1970 兜底生成）
    let year_hrefs: Vec<std::path::PathBuf> = (1970..2100)
        .map(|y| out.join(format!("年度报告_{y}.html")))
        .collect();
    assert!(
        year_hrefs.iter().any(|p| p.exists()),
        "expected at least one 年度报告_*.html under {}",
        out.display()
    );
    assert!(out.join("日历事件.ics").exists());
    // 单文件 HTML 含深空霓虹主题 + 水印
    let html_files: Vec<_> = std::fs::read_dir(&out)
        .unwrap()
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().map(|x| x == "html").unwrap_or(false))
        .collect();
    assert!(!html_files.is_empty());
    let one_html = std::fs::read_to_string(&html_files[0]).unwrap();
    assert!(one_html.contains("--cyan"));
    assert!(one_html.contains("#00f5ff"));
    assert!(one_html.contains("wm-overlay"));

    // 4. 搜索索引
    let hits = core::search_index::search(&out, "吃饭", 20).unwrap();
    assert!(hits.len() >= 1); // 至少找到1条包含"吃饭"的消息
    assert!(hits[0].content.contains("吃饭"));
}

#[test]
fn contact_store_display_name_and_filtering() {
    let tmp = tempfile::tempdir().unwrap();
    let decrypted = tmp.path().join("d");
    build_decrypted_dir(&decrypted);
    let contacts = core::contact_store::load_contacts(&decrypted).unwrap();
    let alice: &ContactItem = contacts.iter().find(|c| c.id == "wxid_alice").unwrap();
    // remark 空 → nick Alice
    assert_eq!(alice.display_name, "Alice");
    // 过滤：只保留内容命中「吃饭」的
    let contact_dir = tmp.path().join("cd");
    core::chat_exporter::export(alice, &decrypted, &contact_dir).unwrap();
    let json = std::fs::read_to_string(contact_dir.join("chat.json")).unwrap();
    let msgs: Vec<core::models::Message> = serde_json::from_str(&json).unwrap();
    let filtered = core::filter::filter_messages(&msgs, None, None, &["吃饭".to_string()]);
    assert_eq!(filtered.len(), 1);
}

#[test]
fn pii_masking_and_wxenc_crosscheck() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    // PII
    assert_eq!(
        core::anon::mask_pii("联系 13812345678 或 abc@qq.com"),
        "联系 138****5678 或 a***@qq.com"
    );
    // .wxenc 往返（字节级）
    let src = dir.join("src");
    std::fs::create_dir_all(&src).unwrap();
    std::fs::write(src.join("a.txt"), "hello 中文").unwrap();
    let enc = dir.join("o.wxenc");
    let mut log = |m: String| eprintln!("{m}");
    core::encrypted::encrypt_directory(&src, "pw", &enc, &mut log).unwrap();
    let dest = dir.join("dest");
    core::encrypted::decrypt_file(&enc, "pw", &dest, &mut log).unwrap();
    assert_eq!(
        std::fs::read(dest.join("a.txt")).unwrap(),
        "hello 中文".as_bytes()
    );
}
