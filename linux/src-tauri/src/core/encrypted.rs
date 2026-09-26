//! 加密导出 `.wxenc`（与 macOS `EncryptedExport.swift` / Windows `EncryptedExport.cs` 字节级互通）
//!
//! 格式：`WXENC`(5) | ver 0x01 | 保留 2 | salt(32) | nonce(12) | ciphertext||tag(16)
//! 密钥：PBKDF2-HMAC-SHA256(password, salt, 100_000, 32)；AES-256-GCM。

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use pbkdf2::pbkdf2_hmac;
use rand::RngCore;
use sha2::Sha256;
use std::path::Path;

const MAGIC: &[u8; 5] = b"WXENC";
const VERSION: u8 = 0x01;
const SALT_LEN: usize = 32;
const NONCE_LEN: usize = 12;
const GCM_TAG_LEN: usize = 16;
const PBKDF2_ROUNDS: u32 = 100_000;
const HEADER_LEN: usize = 5 + 1 + 2 + 32 + 12; // 52

/// key32 = PBKDF2-HMAC-SHA256(password, salt, 100_000, 32)
fn derive_key(password: &[u8], salt: &[u8]) -> [u8; 32] {
    let mut key = [0u8; 32];
    pbkdf2_hmac::<Sha256>(password, salt, PBKDF2_ROUNDS, &mut key);
    key
}

fn random_bytes(n: usize) -> Vec<u8> {
    let mut buf = vec![0u8; n];
    rand::rngs::OsRng.fill_bytes(&mut buf);
    buf
}

/// 递归收集文件，相对路径统一 `/` 分隔，按路径排序保证确定性
fn collect_files(
    dir: &Path,
    prefix: &str,
    entries: &mut Vec<(String, Vec<u8>)>,
) -> std::io::Result<()> {
    let mut subdirs: Vec<(String, std::path::PathBuf)> = Vec::new();
    let mut files: Vec<(String, std::path::PathBuf)> = Vec::new();
    for e in std::fs::read_dir(dir)? {
        let e = e?;
        let path = e.path();
        let name = e.file_name().to_string_lossy().into_owned();
        if path.is_dir() {
            subdirs.push((name, path));
        } else {
            files.push((name, path));
        }
    }
    subdirs.sort_by(|a, b| a.0.cmp(&b.0));
    files.sort_by(|a, b| a.0.cmp(&b.0));
    for (name, path) in subdirs {
        let p = if prefix.is_empty() {
            name.clone()
        } else {
            format!("{prefix}/{name}")
        };
        collect_files(&path, &p, entries)?;
    }
    for (name, path) in files {
        let rel = if prefix.is_empty() {
            name
        } else {
            format!("{prefix}/{name}")
        };
        entries.push((rel, std::fs::read(path)?));
    }
    Ok(())
}

/// 加密目录 → .wxenc 文件（不删除原目录）
pub fn encrypt_directory(
    dir: &Path,
    password: &str,
    dest_file: &Path,
    log: &mut dyn FnMut(String),
) -> Result<(), crate::core::Error> {
    if password.is_empty() {
        return Err(crate::core::err("密码不能为空"));
    }
    let mut entries: Vec<(String, Vec<u8>)> = Vec::new();
    collect_files(dir, "", &mut entries)
        .map_err(|e| crate::core::err(format!("收集文件失败：{e}")))?;
    entries.sort_by(|a, b| a.0.cmp(&b.0));
    if entries.is_empty() {
        return Err(crate::core::err("导出目录为空，无法加密"));
    }

    // 明文 blob
    let mut blob = Vec::new();
    blob.extend_from_slice(&(entries.len() as u64).to_le_bytes());
    for (rel, data) in &entries {
        blob.extend_from_slice(&(data.len() as u64).to_le_bytes());
        blob.extend_from_slice(rel.as_bytes());
        blob.push(0x00);
        blob.extend_from_slice(data);
    }

    let salt = random_bytes(SALT_LEN);
    let nonce_bytes = random_bytes(NONCE_LEN);
    let key = derive_key(password.as_bytes(), &salt);
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key));
    let nonce = Nonce::from_slice(&nonce_bytes);
    let gcm = cipher
        .encrypt(nonce, blob.as_ref())
        .map_err(|_| crate::core::err("加密失败"))?;

    let mut file = Vec::new();
    file.extend_from_slice(MAGIC);
    file.push(VERSION);
    file.extend_from_slice(&[0x00, 0x00]);
    file.extend_from_slice(&salt);
    file.extend_from_slice(&nonce_bytes);
    file.extend_from_slice(&gcm);

    std::fs::write(dest_file, &file)
        .map_err(|e| crate::core::err(format!("写 .wxenc 失败：{e}")))?;
    log(format!(
        "加密导出：{} 个文件 → {}（{}）",
        entries.len(),
        dest_file.file_name().unwrap_or_default().to_string_lossy(),
        crate::core::util::byte_size(file.len() as u64)
    ));
    Ok(())
}

/// 解密 .wxenc → 目标目录，返回还原的文件数
pub fn decrypt_file(
    file_path: &Path,
    password: &str,
    dest_dir: &Path,
    log: &mut dyn FnMut(String),
) -> Result<usize, crate::core::Error> {
    if password.is_empty() {
        return Err(crate::core::err("密码不能为空"));
    }
    let raw =
        std::fs::read(file_path).map_err(|e| crate::core::err(format!("读取 .wxenc 失败：{e}")))?;
    if raw.len() <= HEADER_LEN + GCM_TAG_LEN {
        return Err(crate::core::err("不是有效的 .wxenc 文件（过短）"));
    }
    if &raw[0..5] != MAGIC {
        return Err(crate::core::err("不是有效的 .wxenc 文件（魔数不符）"));
    }
    if raw[5] != VERSION {
        return Err(crate::core::err(format!(
            "不支持的 .wxenc 版本：{}",
            raw[5]
        )));
    }

    let salt = &raw[8..8 + SALT_LEN];
    let nonce_bytes = &raw[40..40 + NONCE_LEN];
    let gcm = &raw[HEADER_LEN..];
    if gcm.len() <= GCM_TAG_LEN {
        return Err(crate::core::err(".wxenc 内容过短"));
    }

    let key = derive_key(password.as_bytes(), salt);
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key));
    let nonce = Nonce::from_slice(nonce_bytes);
    let plain = cipher
        .decrypt(nonce, gcm)
        .map_err(|_| crate::core::err("密码错误或文件已损坏（解密认证失败）"))?;

    // 还原 blob
    let mut entries: Vec<(String, Vec<u8>)> = Vec::new();
    let mut cursor = 0usize;
    let read_u64 = |cursor: &mut usize| -> Option<u64> {
        if *cursor + 8 > plain.len() {
            return None;
        }
        let v = u64::from_le_bytes(plain[*cursor..*cursor + 8].try_into().unwrap());
        *cursor += 8;
        Some(v)
    };
    let count = read_u64(&mut cursor).ok_or_else(|| crate::core::err("blob 损坏"))? as usize;
    for _ in 0..count {
        let data_len = match read_u64(&mut cursor) {
            Some(d) => d as usize,
            None => break,
        };
        // 路径以 0x00 结束
        let nul = match plain[cursor..].iter().position(|&b| b == 0) {
            Some(i) => cursor + i,
            None => break,
        };
        let path = String::from_utf8_lossy(&plain[cursor..nul]).into_owned();
        cursor = nul + 1;
        if path.is_empty() || cursor + data_len > plain.len() {
            break;
        }
        let data = plain[cursor..cursor + data_len].to_vec();
        cursor += data_len;
        entries.push((path, data));
    }

    std::fs::create_dir_all(dest_dir)
        .map_err(|e| crate::core::err(format!("创建目录失败：{e}")))?;
    for (path, data) in &entries {
        let native = path.replace('/', std::path::MAIN_SEPARATOR_STR);
        let url = dest_dir.join(native);
        if let Some(parent) = url.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| crate::core::err(format!("创建目录失败：{e}")))?;
        }
        std::fs::write(&url, data).map_err(|e| crate::core::err(format!("写文件失败：{e}")))?;
    }
    let n = entries.len();
    log(format!("解密完成：{n} 个文件 → {}", dest_dir.display()));
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pbkdf2_known_vector() {
        // 已知向量：PBKDF2-HMAC-SHA256(password="password", salt="salt", c=1, 32B)
        // 用 1 轮直接校验，避免 100_000 轮耗时的同时锁定算法口径
        let mut key = [0u8; 32];
        pbkdf2_hmac::<Sha256>(b"password", b"salt", 1, &mut key);
        assert_eq!(
            hex::encode(key),
            "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"
        );
    }

    #[test]
    fn roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("src");
        std::fs::create_dir_all(src.join("sub")).unwrap();
        std::fs::write(src.join("a.txt"), b"hello").unwrap();
        std::fs::write(src.join("sub/b.txt"), "中文内容".as_bytes()).unwrap();
        let enc = dir.path().join("out.wxenc");
        let mut log = |s: String| eprintln!("{s}");
        encrypt_directory(&src, "secret", &enc, &mut log).unwrap();

        let dest = dir.path().join("dest");
        let n = decrypt_file(&enc, "secret", &dest, &mut log).unwrap();
        assert_eq!(n, 2);
        assert_eq!(std::fs::read(dest.join("a.txt")).unwrap(), b"hello");
        assert_eq!(
            std::fs::read(dest.join("sub/b.txt")).unwrap(),
            "中文内容".as_bytes()
        );
    }

    #[test]
    fn wrong_password_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("src");
        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(src.join("a.txt"), b"x").unwrap();
        let enc = dir.path().join("out.wxenc");
        let mut log = |s: String| eprintln!("{s}");
        encrypt_directory(&src, "right", &enc, &mut log).unwrap();
        let dest = dir.path().join("dest");
        assert!(decrypt_file(&enc, "wrong", &dest, &mut log).is_err());
    }
}
