using System.IO;
using System.Security.Cryptography;

namespace WeChatExporter.Services;

/// <summary>
/// 微信 4.x 数据库加密算法（SQLCipher 4 兼容格式，与 macOS 端 CryptoService.swift 一致）。
/// <para>
/// encKey = PBKDF2-HMAC-SHA512(rawKey, salt, 256000, 32)
/// macKey = PBKDF2-HMAC-SHA512(encKey, salt ^ 0x3A, 2, 32)
/// 每页 4096 字节：IV 位于 [4096-80, 4096-64]，HMAC-SHA512 位于 [4096-64, 4096]，
/// 密文为 [16(第 0 页，跳过 salt) 或 0, 4096-80)。
/// 解密第 0 页后需还原 SQLite 文件头并补零至整页。
/// </para>
/// </summary>
public static class WeChatDbCrypto
{
    public const int PageSize = 4096;
    public const int SaltSize = 16;
    public const int Reserve = 80;      // IV(16) + HMAC(64)
    public const int HmacSize = 64;
    public const int IvSize = 16;
    public const int KdfIterations = 256_000;
    private static readonly byte[] SqliteHeader = "SQLite format 3\0"u8.ToArray();

    /// <summary>读取 db 文件头 16 字节 salt。</summary>
    public static byte[]? ReadSalt(string dbPath)
    {
        try
        {
            using var fs = new FileStream(dbPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            var salt = new byte[SaltSize];
            return fs.Read(salt, 0, SaltSize) == SaltSize ? salt : null;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>由 rawKey 与 db salt 派生该库的加密密钥（32 字节）。</summary>
    public static byte[] DeriveEncKey(byte[] rawKey, byte[] salt)
        => Pbkdf2Sha512(rawKey, salt, KdfIterations, 32);

    /// <summary>派生用于页校验的 macKey（32 字节）。</summary>
    public static byte[] DeriveMacKey(byte[] encKey, byte[] salt)
    {
        var macSalt = new byte[salt.Length];
        for (var i = 0; i < salt.Length; i++)
            macSalt[i] = (byte)(salt[i] ^ 0x3A);
        return Pbkdf2Sha512(encKey, macSalt, 2, 32);
    }

    /// <summary>
    /// 校验 rawKey 是否为该 db 的正确密钥（用第 0 页 HMAC 验证）。
    /// 所有微信 4.x 数据库共用同一 rawKey，任一 db 均可验证。
    /// </summary>
    public static bool ValidateRawKey(byte[] rawKey, string dbPath)
    {
        try
        {
            if (rawKey.Length != 32) return false;
            using var fs = new FileStream(dbPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            var page = ReadPage(fs, 0);
            if (page.Length < PageSize) return false;
            var salt = page.AsSpan(0, SaltSize).ToArray();
            var encKey = DeriveEncKey(rawKey, salt);
            var macKey = DeriveMacKey(encKey, salt);
            return VerifyHmacPage(page, macKey);
        }
        catch
        {
            return false;
        }
    }

    /// <summary>将加密 db 解密为明文 SQLite 数据库字节流（含 SQLite 文件头）。</summary>
    public static byte[] DecryptDatabase(byte[] rawKey, string dbPath)
    {
        using var fs = new FileStream(dbPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        var total = fs.Length;
        if (total < PageSize)
            throw new InvalidOperationException($"文件过小：{Path.GetFileName(dbPath)}");

        var salt = ReadPage(fs, 0).AsSpan(0, SaltSize).ToArray();
        var encKey = DeriveEncKey(rawKey, salt);
        var macKey = DeriveMacKey(encKey, salt);

        using var output = new MemoryStream((int)total);
        var totalPages = (int)((total + PageSize - 1) / PageSize);
        for (var pageIndex = 0; pageIndex < totalPages; pageIndex++)
        {
            var page = ReadPage(fs, pageIndex);
            var decrypted = DecryptPage(page, encKey, macKey, pageIndex);
            output.Write(decrypted);
        }
        return output.ToArray();
    }

    private static byte[] ReadPage(FileStream fs, int index)
    {
        var buffer = new byte[PageSize];
        fs.Position = (long)index * PageSize;
        var read = fs.Read(buffer, 0, PageSize);
        if (read < PageSize)
            Array.Clear(buffer, read, PageSize - read);
        return buffer;
    }

    private static bool VerifyHmacPage(byte[] page, byte[] macKey)
    {
        var hmacDataEnd = PageSize - Reserve + IvSize;                 // 4096-80+16 = 4032
        var storedStart = hmacDataEnd;                                 // 4032..4096 存 HMAC
        var pageNumber = BitConverter.GetBytes(1);                     // 第 1 页（第 0 页校验时页号=1）
        var macData = new byte[(hmacDataEnd - SaltSize) + 4];
        Array.Copy(page, SaltSize, macData, 0, hmacDataEnd - SaltSize);
        Array.Copy(pageNumber, 0, macData, hmacDataEnd - SaltSize, 4);

        var computed = HmacSha512(macKey, macData);
        var stored = page.AsSpan(storedStart, HmacSize);
        return computed.AsSpan().SequenceEqual(stored);
    }

    private static byte[] DecryptPage(byte[] page, byte[] encKey, byte[] macKey, int pageNumber)
    {
        var ivStart = PageSize - Reserve;                              // 4016
        var iv = page.AsSpan(ivStart, IvSize).ToArray();
        var encryptedStart = pageNumber == 0 ? SaltSize : 0;
        var encryptedEnd = PageSize - Reserve;                         // 4016
        var encrypted = page.AsSpan(encryptedStart, encryptedEnd - encryptedStart).ToArray();

        var decrypted = AesCbcDecrypt(encrypted, encKey, iv);

        if (pageNumber == 0)
        {
            // 第 0 页：还原 SQLite 文件头，数据区 = 解密后的 [0, 4096-16-80)，尾部补零
            var result = new byte[PageSize];
            Array.Copy(SqliteHeader, 0, result, 0, SqliteHeader.Length);
            var copyLen = Math.Min(decrypted.Length, PageSize - SqliteHeader.Length);
            Array.Copy(decrypted, 0, result, SqliteHeader.Length, copyLen);
            return result;
        }

        var outPage = new byte[PageSize];
        var len = Math.Min(decrypted.Length, PageSize - Reserve);
        Array.Copy(decrypted, 0, outPage, 0, len);
        return outPage;
    }

    private static byte[] AesCbcDecrypt(byte[] data, byte[] key, byte[] iv)
    {
        using var aes = Aes.Create();
        aes.Key = key;
        aes.IV = iv;
        aes.Mode = CipherMode.CBC;
        aes.Padding = PaddingMode.PKCS7;
        using var decryptor = aes.CreateDecryptor();
        return decryptor.TransformFinalBlock(data, 0, data.Length);
    }

    /// <summary>PBKDF2-HMAC-SHA512（.NET 内置 Rfc2898DeriveBytes 仅支持 SHA1/SHA256，此处手写）。</summary>
    public static byte[] Pbkdf2Sha512(byte[] password, byte[] salt, int iterations, int keyLength)
    {
        using var hmac = new HMACSHA512(password);
        var hashLen = hmac.HashSize / 8;                               // 64
        var blocks = (keyLength + hashLen - 1) / hashLen;
        var result = new byte[blocks * hashLen];
        var blockInput = new byte[salt.Length + 4];
        Array.Copy(salt, blockInput, salt.Length);

        for (var block = 1; block <= blocks; block++)
        {
            blockInput[salt.Length] = (byte)(block >> 24);
            blockInput[salt.Length + 1] = (byte)(block >> 16);
            blockInput[salt.Length + 2] = (byte)(block >> 8);
            blockInput[salt.Length + 3] = (byte)block;

            var t = hmac.ComputeHash(blockInput);
            var u = t;
            for (var i = 1; i < iterations; i++)
            {
                u = hmac.ComputeHash(u);
                for (var j = 0; j < hashLen; j++)
                    t[j] ^= u[j];
            }
            Array.Copy(t, 0, result, (block - 1) * hashLen, hashLen);
        }
        return result[..keyLength];
    }

    public static byte[] HmacSha512(byte[] key, byte[] data)
    {
        using var hmac = new HMACSHA512(key);
        return hmac.ComputeHash(data);
    }
}
