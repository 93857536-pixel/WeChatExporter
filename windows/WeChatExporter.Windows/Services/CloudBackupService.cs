using System.IO;
using System.Net;
using System.Security.Cryptography;
using WeChatExporter.Models;

namespace WeChatExporter.Services;

/// <summary>
/// 云备份业务编排：E2EE 加密 → manifest → 分块上传 → commit；以及分块下载 → 组装 .wxenc → 解密。
/// 复用现有 EncryptedExport（AES-256-GCM + PBKDF2-SHA256 100k，52B 头，与 macOS 端互通）。
/// 密码只在本类内存中传递，绝不出现在任何 HTTP 请求里。
/// 全部 CPU 重活（加密/哈希/落盘）走 Task.Run，网络走 async，UI 线程零阻塞（#39 教训）。
/// </summary>
public static class CloudBackupService
{
    /// <summary>云端固定文件名（同名覆盖，重复备份 = 更新）。</summary>
    public const string BackupFileName = "wechat-export.wxenc";

    /// <summary>分块大小 1 MiB（契约允许 65536..8388608）。</summary>
    public const int ChunkSize = 1024 * 1024;

    /// <summary>并发上传数上限。</summary>
    public const int MaxConcurrency = 3;

    /// <summary>失败重试次数（指数退避）。</summary>
    public const int MaxRetries = 3;

    /// <summary>
    /// 把导出目录整体加密为 .wxenc 并上传（同名覆盖）。返回 (usedBytes, quotaBytes)。
    /// 内部在后台线程运行，progress 从 0→1 反映「加密+上传」整体进度。
    /// </summary>
    public static Task<(long UsedBytes, long QuotaBytes)> UploadDirectoryAsync(
        CloudBackupClient client, string directory, string password,
        Action<string> log, Action<double>? progress, CancellationToken ct = default)
        => Task.Run(() => UploadDirectoryCoreAsync(client, directory, password, log, progress, ct), ct);

    private static async Task<(long, long)> UploadDirectoryCoreAsync(
        CloudBackupClient client, string directory, string password,
        Action<string> log, Action<double>? progress, CancellationToken ct)
    {
        var tempDir = Path.Combine(Path.GetTempPath(), $"wce-cloud-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);
        var blobPath = Path.Combine(tempDir, BackupFileName);
        try
        {
            log("云备份：正在加密导出目录（AES-256-GCM + PBKDF2-SHA256，大目录耗时较长）…");
            await Task.Run(() => EncryptedExport.EncryptDirectory(directory, password, blobPath, log), ct).ConfigureAwait(false);

            var totalSize = new FileInfo(blobPath).Length;
            log($"云备份：加密完成 {BackupFileName}（{EncryptedExport.FormatSize(totalSize)}），正在计算 SHA-256…");

            string sha256 = await Task.Run(() =>
            {
                using var fs = File.OpenRead(blobPath);
                using var sha = SHA256.Create();
                return Convert.ToHexString(sha.ComputeHash(fs)).ToLowerInvariant();
            }, ct).ConfigureAwait(false);

            var chunkCount = (int)((totalSize + ChunkSize - 1) / ChunkSize);
            if (chunkCount <= 0) chunkCount = 1;

            var entry = new ManifestEntry
            {
                Name = BackupFileName,
                Category = "other",
                Sha256 = sha256,
                TotalSize = totalSize,
                ChunkCount = chunkCount,
                ChunkSize = ChunkSize,
            };

            log($"云备份：提交清单（{chunkCount} 块，每块 {EncryptedExport.FormatSize(ChunkSize)}）…");
            var submit = await client.SubmitManifestAsync(entry, ct).ConfigureAwait(false);

            if (submit.SkipUpload)
            {
                log($"云备份：服务端内容未变（sha256 命中），已跳过上传。已用 {EncryptedExport.FormatSize(submit.UsedBytes)} / {EncryptedExport.FormatSize(submit.QuotaBytes)}");
                progress?.Invoke(1.0);
                return (submit.UsedBytes, submit.QuotaBytes);
            }

            log($"云备份：开始上传 {chunkCount} 块（并发 ≤ {MaxConcurrency}，失败自动重试）…");
            var blob = await Task.Run(() => File.ReadAllBytes(blobPath), ct).ConfigureAwait(false);
            await UploadChunksAsync(client, blob, totalSize, chunkCount, log, progress, ct).ConfigureAwait(false);

            log("云备份：所有分块已上传，提交中…");
            var (size, used, quota) = await client.CommitAsync(BackupFileName, ct).ConfigureAwait(false);
            log($"云备份：完成 {BackupFileName}（{EncryptedExport.FormatSize(size)}），已用 {EncryptedExport.FormatSize(used)} / {EncryptedExport.FormatSize(quota)}");
            progress?.Invoke(1.0);
            return (used, quota);
        }
        finally
        {
            try { Directory.Delete(tempDir, true); } catch { /* ignore */ }
        }
    }

    private static async Task UploadChunksAsync(
        CloudBackupClient client, byte[] blob, long totalSize, int chunkCount,
        Action<string> log, Action<double>? progress, CancellationToken ct)
    {
        using var sem = new SemaphoreSlim(MaxConcurrency);
        int completed = 0;
        int lastBucket = -1;

        async Task UploadOneAsync(int idx)
        {
            await sem.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                var offset = (long)idx * ChunkSize;
                var len = (int)Math.Min(ChunkSize, totalSize - offset);
                var chunk = new byte[len];
                Array.Copy(blob, offset, chunk, 0, len);
                var b64 = Convert.ToBase64String(chunk);

                Exception? last = null;
                for (int attempt = 1; attempt <= MaxRetries; attempt++)
                {
                    try
                    {
                        await client.UploadChunkAsync(BackupFileName, idx, b64, ct).ConfigureAwait(false);
                        last = null;
                        break;
                    }
                    catch (CloudApiException ex) when (ex.StatusCode == HttpStatusCode.TooManyRequests && attempt < MaxRetries)
                    {
                        last = ex;
                        await Task.Delay(TimeSpan.FromSeconds(Math.Pow(2, attempt)), ct).ConfigureAwait(false);
                    }
                    catch (Exception ex)
                    {
                        last = ex;
                        if (attempt < MaxRetries)
                            await Task.Delay(TimeSpan.FromSeconds(Math.Pow(2, attempt)), ct).ConfigureAwait(false);
                        else
                            throw;
                    }
                }
                if (last is not null) throw last;

                var done = Interlocked.Increment(ref completed);
                var pct = (int)(done * 100L / chunkCount);
                var bucket = pct / 10;
                if (bucket != lastBucket)
                {
                    lastBucket = bucket;
                    log($"云备份：上传进度 {pct}%（{done}/{chunkCount} 块）");
                }
                progress?.Invoke(done / (double)chunkCount);
            }
            finally
            {
                sem.Release();
            }
        }

        var tasks = new List<Task>(chunkCount);
        for (int i = 0; i < chunkCount; i++) tasks.Add(UploadOneAsync(i));
        await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    /// <summary>
    /// 分块下载 → 组装 .wxenc 到 destWxencPath → 解密到 decryptDir。
    /// progress 从 0→1 反映下载进度（解密阶段单列，不计入百分比）。
    /// </summary>
    public static Task DownloadAndDecryptAsync(
        CloudBackupClient client, CloudBackupItem item, string destWxencPath, string decryptDir, string password,
        Action<string> log, Action<double>? progress, CancellationToken ct = default)
        => Task.Run(() => DownloadAndDecryptCoreAsync(client, item, destWxencPath, decryptDir, password, log, progress, ct), ct);

    private static async Task DownloadAndDecryptCoreAsync(
        CloudBackupClient client, CloudBackupItem item, string destWxencPath, string decryptDir, string password,
        Action<string> log, Action<double>? progress, CancellationToken ct)
    {
        log($"云备份：开始下载 {item.Name}（{item.ChunkCount} 块，共 {EncryptedExport.FormatSize(item.TotalSize)}）…");

        Directory.CreateDirectory(Path.GetDirectoryName(destWxencPath) ?? ".");
        using (var fs = new FileStream(destWxencPath, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            long written = 0;
            int lastBucket = -1;
            for (int idx = 0; idx < item.ChunkCount; idx++)
            {
                var chunk = await DownloadChunkWithRetryAsync(client, item.Name, idx, ct).ConfigureAwait(false);
                await fs.WriteAsync(chunk, ct).ConfigureAwait(false);
                written += chunk.Length;
                var pct = item.TotalSize > 0 ? (int)(written * 100L / item.TotalSize) : 100;
                var bucket = pct / 10;
                if (bucket != lastBucket)
                {
                    lastBucket = bucket;
                    log($"云备份：下载进度 {pct}%（{written}/{item.TotalSize} 字节）");
                }
                progress?.Invoke(item.TotalSize > 0 ? written / (double)item.TotalSize : 1.0);
            }
        }

        log($"云备份：下载完成，已组装 {destWxencPath}（{EncryptedExport.FormatSize(new FileInfo(destWxencPath).Length)}）");
        log("云备份：正在解密（AES-256-GCM）…");
        var n = await Task.Run(() => EncryptedExport.DecryptFile(destWxencPath, password, decryptDir, log), ct).ConfigureAwait(false);
        log($"云备份：解密完成 {n} 个文件 → {decryptDir}");
    }

    private static async Task<byte[]> DownloadChunkWithRetryAsync(CloudBackupClient client, string name, int idx, CancellationToken ct)
    {
        Exception? last = null;
        for (int attempt = 1; attempt <= MaxRetries; attempt++)
        {
            try
            {
                return await client.DownloadChunkAsync(name, idx, ct).ConfigureAwait(false);
            }
            catch (CloudApiException ex) when (ex.StatusCode == HttpStatusCode.TooManyRequests && attempt < MaxRetries)
            {
                last = ex;
                await Task.Delay(TimeSpan.FromSeconds(Math.Pow(2, attempt)), ct).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                last = ex;
                if (attempt < MaxRetries)
                    await Task.Delay(TimeSpan.FromSeconds(Math.Pow(2, attempt)), ct).ConfigureAwait(false);
                else
                    throw;
            }
        }
        throw last!;
    }
}
