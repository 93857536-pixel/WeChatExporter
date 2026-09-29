using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace WeChatExporter.Services;

/// <summary>
/// 加密导出：把导出目录整体加密为单个 .wxenc 文件（AES-256-GCM，PBKDF2-SHA256 派生密钥）。
/// 与 macOS 端 (Services/EncryptedExport.swift) 字节级互通，同一密码两端可互相加解密。
/// 密码只在内存中持有，不落盘。
///
/// 文件格式（.wxenc）：
///   [0..5)    魔数 "WXENC"
///   [5]      版本 0x01
///   [6..8)    保留 0x00 0x00
///   [8..40)   salt (32)
///   [40..52)  nonce (12, AES-GCM)
///   [52..n)   ciphertext || tag16 (AES-256-GCM 密文后拼 16 字节认证标签)
///
/// 密钥：key32 = PBKDF2-HMAC-SHA256(password, salt, 100_000, 32)
/// 明文 blob：
///   count (8 bytes LE)
///   每项：dataLen (8 bytes LE) | pathUTF8 + 0x00 | data
///   相对路径统一用 "/" 分隔（跨平台），按路径排序保证确定性
/// </summary>
public static class EncryptedExport
{
    private static readonly byte[] Magic = Encoding.ASCII.GetBytes("WXENC");
    private const byte Version = 0x01;
    private const int SaltLen = 32;
    private const int NonceLen = 12;
    private const int GcmTagLen = 16;
    private const int Pbkdf2Rounds = 100_000;
    private const int HeaderLen = 5 + 1 + 2 + 32 + 12; // = 52

    public sealed class EncryptedExportException : Exception
    {
        public EncryptedExportException(string message) : base(message) { }
    }

    /// <summary>将目录整体加密写入 .wxenc 文件（不删除原目录，由调用方决定）</summary>
    public static string EncryptDirectory(string directory, string password, string destFile, Action<string>? log = null)
    {
        if (string.IsNullOrEmpty(password)) throw new EncryptedExportException("密码不能为空");
        var root = Path.GetFullPath(directory);
        if (!Directory.Exists(root)) throw new EncryptedExportException($"导出目录不存在：{root}");

        // 收集文件（手工递归组相对路径，统一 / 分隔，不依赖符号链接解析；按路径排序保证确定性）
        var entries = new List<(string RelPath, byte[] Data)>();
        CollectFiles(root, string.Empty, entries);
        entries.Sort(static (a, b) => string.CompareOrdinal(a.RelPath, b.RelPath));
        if (entries.Count == 0) throw new EncryptedExportException("导出目录为空，无法加密");

        // 明文 blob
        using var blob = new MemoryStream();
        WriteInt64LE(blob, entries.Count);
        foreach (var (rel, data) in entries)
        {
            WriteInt64LE(blob, data.Length);
            var pathBytes = Encoding.UTF8.GetBytes(rel);
            blob.Write(pathBytes);
            blob.WriteByte(0);
            blob.Write(data);
        }
        var plain = blob.ToArray();

        // 密钥派生 + GCM 加密
        var salt = RandomNumberGenerator.GetBytes(SaltLen);
        var nonce = RandomNumberGenerator.GetBytes(NonceLen);
        var key = DeriveKey(password, salt);
        var cipher = new byte[plain.Length];
        var tag = new byte[GcmTagLen];
        using var aes = new AesGcm(key, GcmTagLen);
        aes.Encrypt(nonce, plain, cipher, tag);
        var gcm = new byte[cipher.Length + tag.Length];
        Buffer.BlockCopy(cipher, 0, gcm, 0, cipher.Length);
        Buffer.BlockCopy(tag, 0, gcm, cipher.Length, tag.Length);

        var file = new byte[HeaderLen + gcm.Length];
        Magic.CopyTo(file, 0);
        file[5] = Version;
        // [6..8) 保留 0
        salt.CopyTo(file, 8);
        nonce.CopyTo(file, 40);
        gcm.CopyTo(file, HeaderLen);

        File.WriteAllBytes(destFile, file);
        log?.Invoke($"加密导出：{entries.Count} 个文件 → {Path.GetFileName(destFile)}（{FormatSize(file.Length)}）");
        return destFile;
    }

    /// <summary>解密 .wxenc 到目标目录，返回还原的文件数</summary>
    public static int DecryptFile(string file, string password, string destDir, Action<string>? log = null)
    {
        var entries = ReadEntries(file, password);

        Directory.CreateDirectory(destDir);
        foreach (var (path, data) in entries)
        {
            var native = path.Replace('/', Path.DirectorySeparatorChar);
            var url = Path.GetFullPath(Path.Combine(destDir, native));
            Directory.CreateDirectory(Path.GetDirectoryName(url)!);
            File.WriteAllBytes(url, data);
        }
        log?.Invoke($"解密完成：{entries.Count} 个文件 → {destDir}");
        return entries.Count;
    }

    /// <summary>
    /// 只解密并解析归档条目（不落盘），返回 相对路径 → 字节数。
    /// 用于「加密后、删除明文前」的完整性校验：校验不过就不删明文，避免用户两头空。
    /// </summary>
    public static Dictionary<string, long> Inspect(string file, string password)
    {
        var entries = ReadEntries(file, password);
        var result = new Dictionary<string, long>(StringComparer.Ordinal);
        foreach (var (path, data) in entries)
            result[path] = data.Length;
        return result;
    }

    /// <summary>读取并解密 .wxenc，返回 相对路径 → 内容（内存，不落盘）。</summary>
    private static Dictionary<string, byte[]> ReadEntries(string file, string password)
    {
        if (string.IsNullOrEmpty(password)) throw new EncryptedExportException("密码不能为空");
        var raw = File.ReadAllBytes(file);
        if (raw.Length <= HeaderLen + GcmTagLen) throw new EncryptedExportException("不是有效的 .wxenc 文件（过短）");
        for (int i = 0; i < 5; i++)
        {
            if (raw[i] != Magic[i]) throw new EncryptedExportException("不是有效的 .wxenc 文件（魔数不符）");
        }
        if (raw[5] != Version) throw new EncryptedExportException($"不支持的 .wxenc 版本：{raw[5]}");

        var salt = raw[8..(8 + SaltLen)];
        var nonce = raw[40..(40 + NonceLen)];
        var gcm = raw[HeaderLen..];
        if (gcm.Length <= GcmTagLen) throw new EncryptedExportException(".wxenc 内容过短");

        var cipher = gcm[..^GcmTagLen];
        var tag = gcm[^GcmTagLen..];
        var key = DeriveKey(password, salt);

        byte[] plain;
        try
        {
            using var aes = new AesGcm(key, GcmTagLen);
            plain = new byte[cipher.Length];
            aes.Decrypt(nonce, cipher, tag, plain);
        }
        catch (CryptographicException)
        {
            throw new EncryptedExportException("密码错误或文件已损坏（解密认证失败）");
        }

        // 还原 blob
        var entries = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        var cursor = 0;
        long ReadInt64()
        {
            var start = cursor;
            cursor += 8;
            long v = 0;
            for (int i = 0; i < 8; i++) v |= (long)plain[start + i] << (8 * i);
            return v;
        }
        var count = ReadInt64();
        for (long i = 0; i < count; i++)
        {
            var dataLen = ReadInt64();
            if (cursor + 8 > plain.Length) break;
            // 路径以 0x00 结束
            int nul = -1;
            for (int j = cursor; j < plain.Length; j++)
            {
                if (plain[j] == 0) { nul = j; break; }
            }
            if (nul < 0) break;
            var pathBytes = plain[cursor..nul];
            cursor = nul + 1;
            var path = Encoding.UTF8.GetString(pathBytes);
            if (path.Length == 0) continue;
            if (cursor + dataLen > plain.Length) break;
            var data = plain[cursor..(int)(cursor + dataLen)];
            cursor += (int)dataLen;
            entries[path] = data;
        }
        return entries;
    }

    /// <summary>密钥：PBKDF2-HMAC-SHA256(password, salt, 100_000, 32)，与 Swift 端字节一致</summary>
    internal static byte[] DeriveKey(string password, byte[] salt)
    {
        return Rfc2898DeriveBytes.Pbkdf2(
            Encoding.UTF8.GetBytes(password),
            salt,
            Pbkdf2Rounds,
            HashAlgorithmName.SHA256,
            32);
    }

    internal static string FormatSize(long bytes)
    {
        if (bytes >= 1L << 30) return $"{bytes / (double)(1L << 30):0.#} GB";
        if (bytes >= 1L << 20) return $"{bytes / (double)(1L << 20):0.#} MB";
        if (bytes >= 1024) return $"{bytes / 1024:0} KB";
        return $"{bytes} B";
    }

    /// 手工递归收集文件，相对路径统一用 / 分隔（跨平台可移植），不依赖符号链接解析
    private static void CollectFiles(string dir, string prefix, List<(string RelPath, byte[] Data)> entries)
    {
        foreach (var sub in Directory.GetDirectories(dir))
        {
            var subName = Path.GetFileName(sub);
            CollectFiles(sub, string.IsNullOrEmpty(prefix) ? subName : prefix + "/" + subName, entries);
        }
        foreach (var file in Directory.GetFiles(dir))
        {
            var name = Path.GetFileName(file);
            var rel = string.IsNullOrEmpty(prefix) ? name : prefix + "/" + name;
            entries.Add((rel, File.ReadAllBytes(file)));
        }
    }

    private static void WriteInt64LE(Stream s, long v)
    {
        for (int i = 0; i < 8; i++)
        {
            s.WriteByte((byte)((v >> (8 * i)) & 0xFF));
        }
    }
}
