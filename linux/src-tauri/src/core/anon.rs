//! 脱敏导出（SPEC §3）：名称伪化 + PII 模糊化 + 映射文件

use crate::core::Result;
use std::collections::BTreeMap;
use std::path::Path;

/// 伪名分配：0→用户A ... 25→用户Z，26→用户AA ...（与 SPEC §3 一致）
pub fn pseudo_name(index: usize) -> String {
    let mut n = index;
    let mut s = String::new();
    loop {
        let rem = n % 26;
        s.insert(0, (b'A' + rem as u8) as char);
        if n < 26 {
            break;
        }
        n = n / 26 - 1;
    }
    format!("用户{s}")
}

/// PII 模糊化（手机号 / 身份证 / 邮箱），单遍扫描实现（无 lookaround 依赖）
pub fn mask_pii(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let n = chars.len();
    let mut out = String::with_capacity(n);
    let mut i = 0;
    while i < n {
        // 手机号：1[3-9] + 9 位，前后非数字
        if chars[i] == '1'
            && i + 11 <= n
            && (i == 0 || !chars[i - 1].is_ascii_digit())
            && (i + 11 == n || !chars[i + 11].is_ascii_digit())
            && matches!(chars[i + 1], '3'..='9')
            && chars[i + 2..i + 11].iter().all(|c| c.is_ascii_digit())
        {
            let head: String = chars[i..i + 3].iter().collect();
            let tail: String = chars[i + 7..i + 11].iter().collect();
            out.push_str(&format!("{head}****{tail}"));
            i += 11;
            continue;
        }
        // 身份证 18 位：17 位数字 + 数字/X，前后非数字
        if i + 18 <= n
            && (i == 0 || !chars[i - 1].is_ascii_digit())
            && (i + 18 == n || !chars[i + 18].is_ascii_digit())
            && chars[i..i + 17].iter().all(|c| c.is_ascii_digit())
            && (chars[i + 17].is_ascii_digit() || chars[i + 17] == 'X' || chars[i + 17] == 'x')
        {
            let head: String = chars[i..i + 6].iter().collect();
            let tail: String = chars[i + 16..i + 18].iter().collect();
            out.push_str(&format!("{head}**********{tail}"));
            i += 18;
            continue;
        }
        // 邮箱：找到 @，向两侧扩展 local/domain
        if chars[i] == '@' && i > 0 && i + 1 < n {
            let mut local_start = i;
            while local_start > 0 {
                let c = chars[local_start - 1];
                if c.is_ascii_alphanumeric() || "._%+-".contains(c) {
                    local_start -= 1;
                } else {
                    break;
                }
            }
            let mut domain_end = i + 1;
            while domain_end < n {
                let c = chars[domain_end];
                if c.is_ascii_alphanumeric() || ".-".contains(c) {
                    domain_end += 1;
                } else {
                    break;
                }
            }
            let local = &chars[local_start..i];
            let domain: String = chars[i + 1..domain_end].iter().collect();
            if !local.is_empty() && domain.contains('.') {
                // 回退 local 部分已逐字推入的字符（只保留首字符）
                for _ in 0..(i - local_start) {
                    out.pop();
                }
                out.push(local[0]);
                out.push_str("***@");
                out.push_str(&domain);
                i = domain_end;
                continue;
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

/// 名称伪化映射：按名称排序确定性分配 用户A/B/C...
pub fn build_name_map(names: &std::collections::BTreeSet<String>) -> BTreeMap<String, String> {
    names
        .iter()
        .enumerate()
        .map(|(i, name)| (name.clone(), pseudo_name(i)))
        .collect()
}

/// 对导出根目录下文本产物做脱敏替换；返回映射表（供写映射文件）
pub fn anonymize_directory(
    export_root: &Path,
    mask_pii: bool,
    _keep_mapping: bool,
    log: &mut dyn FnMut(String),
) -> Result<BTreeMap<String, String>> {
    // 1. 收集所有出现的名称：会话目录名 + chat.json 里的 sender
    let mut names: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    let mut json_files: Vec<std::path::PathBuf> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(export_root) {
        for e in entries.filter_map(|e| e.ok()) {
            let p = e.path();
            if p.is_dir() {
                let name = e.file_name().to_string_lossy().into_owned();
                names.insert(name.clone());
                let json = p.join("chat.json");
                if json.exists() {
                    json_files.push(json);
                }
            }
        }
    }
    for jf in &json_files {
        if let Ok(data) = std::fs::read_to_string(jf) {
            if let Ok(msgs) = serde_json::from_str::<Vec<crate::core::models::Message>>(&data) {
                for m in msgs {
                    if !m.sender.is_empty() {
                        names.insert(m.sender);
                    }
                }
            }
        }
    }

    let name_map = build_name_map(&names);
    // 按名称长度降序替换，避免「用户A」前缀误伤
    let mut sorted_names: Vec<&String> = name_map.keys().collect();
    sorted_names.sort_by(|a, b| b.chars().count().cmp(&a.chars().count()));

    // 2. 替换文本产物
    let mut artifacts: Vec<std::path::PathBuf> = json_files;
    for ext in ["txt", "csv", "html"] {
        if let Ok(entries) = std::fs::read_dir(export_root) {
            for e in entries.filter_map(|e| e.ok()) {
                let p = e.path();
                if p.is_file() && p.extension().map(|x| x == ext).unwrap_or(false) {
                    artifacts.push(p);
                }
            }
        }
    }
    artifacts.sort();
    artifacts.dedup();

    let mut changed = 0;
    for f in &artifacts {
        let raw = match std::fs::read_to_string(f) {
            Ok(r) => r,
            Err(_) => continue,
        };
        let mut replaced = raw.clone();
        for name in &sorted_names {
            let pseudo = &name_map[*name];
            replaced = replaced.replace(*name, pseudo);
        }
        if mask_pii {
            replaced = crate::core::anon::mask_pii(&replaced);
        }
        if replaced != raw {
            if std::fs::write(f, replaced).is_ok() {
                changed += 1;
            }
        }
    }
    log(format!(
        "脱敏完成：替换 {} 份产物、{} 个名称",
        changed,
        name_map.len()
    ));
    Ok(name_map)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pseudo_name_sequence() {
        assert_eq!(pseudo_name(0), "用户A");
        assert_eq!(pseudo_name(25), "用户Z");
        assert_eq!(pseudo_name(26), "用户AA");
        assert_eq!(pseudo_name(27), "用户AB");
    }

    #[test]
    fn mask_phone_id_email() {
        assert_eq!(mask_pii("电话 13812345678 找我"), "电话 138****5678 找我");
        assert_eq!(
            mask_pii("身份证 110101199003078515 号"),
            "身份证 110101**********15 号"
        );
        assert_eq!(mask_pii("邮箱 abc@qq.com 联系"), "邮箱 a***@qq.com 联系");
    }
}
